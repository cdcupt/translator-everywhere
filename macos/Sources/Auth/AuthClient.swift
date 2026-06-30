import AppKit
import Foundation

/// Bridges a browser-based OAuth round-trip back into the app.
///
/// A provider registers the `state` it expects and opens the login URL in the
/// user's default browser; when the OS delivers the post-login redirect to one
/// of the app's registered URL schemes, `AppDelegate` forwards it here and the
/// matching awaiter resumes with the callback URL.
///
/// This deliberately replaces `ASWebAuthenticationSession`: on macOS that API
/// routes the login to the *default browser* and is broken when that browser is
/// Chrome/Firefox (the auth window opens then immediately closes, so no page is
/// shown). Driving the browser ourselves + capturing the custom-scheme redirect
/// works with any default browser.
@MainActor
final class WebAuthRouter {
    static let shared = WebAuthRouter()

    /// In-flight sign-ins, keyed by the OAuth `state` we expect echoed back.
    private var waiters: [String: CheckedContinuation<URL, Error>] = [:]

    /// Opens `url` in the default browser and suspends until a redirect whose
    /// `state` query equals `state` is delivered to `handle`. Throws
    /// `AuthError.providerResponseInvalid` if the URL can't be opened.
    ///
    /// Cancellation-aware: if the awaiting task is cancelled (the sign-in
    /// watchdog timed out), the waiter is dropped and the task unblocked, so a
    /// LATE redirect finds no awaiter and is ignored — never completing a sign-in
    /// the UI has already abandoned.
    func open(_ url: URL, awaitingState state: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Register before opening so an instant redirect can't outrace us.
                waiters[state] = continuation
                if !NSWorkspace.shared.open(url) {
                    waiters[state] = nil
                    continuation.resume(throwing: AuthError.providerResponseInvalid)
                }
            }
        } onCancel: { [self] in
            Task { @MainActor in
                if let continuation = waiters.removeValue(forKey: state) {
                    continuation.resume(throwing: AuthError.cancelled)
                }
            }
        }
    }

    /// Suspends until `handle` receives a redirect whose `state` matches. The
    /// registration seam `open` is built on; exposed so the routing can be
    /// unit-tested without opening a real browser.
    func awaitRedirect(matchingState state: String) async throws -> URL {
        try await withCheckedThrowingContinuation { waiters[state] = $0 }
    }

    /// Resumes the awaiter whose `state` matches `url`, returning whether one was
    /// found. Called by `AppDelegate` for every incoming custom-scheme URL.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let state = Self.state(from: url),
              let continuation = waiters.removeValue(forKey: state)
        else { return false }
        continuation.resume(returning: url)
        return true
    }

    private static func state(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "state" })?.value
    }
}

/// Acquires a Google authorization `code` by driving the system browser. The
/// real implementation runs a localhost loopback redirect (Google's Desktop-app
/// pattern); tests inject a stub so the PKCE token-exchange + backend POST can run
/// headlessly.
protocol GoogleAuthorizationProvider: Sendable {
    /// Drives the browser consent + loopback capture. `buildAuthorizationURL` is
    /// invoked with the loopback `redirect_uri` (known only once the listener
    /// binds an ephemeral port) to construct the authorize URL. Returns the `code`
    /// from the redirect (after validating `state`) AND the exact `redirectURI`
    /// used — the caller MUST pass that same value to the token exchange, because
    /// Google requires the authorize and token `redirect_uri` to be identical.
    func authorizationCode(
        expectedState: String,
        buildAuthorizationURL: (_ redirectURI: String) -> URL
    ) async throws -> (code: String, redirectURI: String)
}

/// Sign-in via the system browser (TECH §8.6).
///
/// Both Apple and Google open the login in the user's default browser, but capture
/// the redirect differently and diverge in who does the token exchange:
/// - **Google**: a Desktop-app OAuth client with a **loopback** redirect — the app
///   binds `127.0.0.1` (`LoopbackRedirectListener`), opens the consent page,
///   captures the `?code` on localhost, runs PKCE to exchange it for an `id_token`,
///   POSTs that to `/auth/google`, and receives our session JWT + refresh. (Custom
///   URL schemes are unreliable on desktop Chrome; loopback is Google's documented
///   desktop pattern.)
/// - **Apple (web flow)**: the app opens Apple's `/auth/authorize`; Apple
///   redirects to our backend, which verifies the `code`, mints our session, and
///   302s back to the app's custom scheme carrying `session`+`refresh` directly —
///   so there's no native entitlement and no on-device token exchange.
///
/// Both end the same way: store the session JWT + refresh in the Keychain and
/// return the `AuthSession`. The app works fully without ever signing in — this
/// only enables cross-Mac sync.
final class AuthClient {

    private let session: URLSession
    private let tokens: TokenStore
    private let googleAuthProvider: GoogleAuthorizationProvider
    private let appleAuthProvider: AppleWebAuthorizationProvider
    private let baseURL: URL

    init(
        session: URLSession = .shared,
        tokens: TokenStore = TokenStore(),
        baseURL: URL = AuthConfig.backendBaseURL,
        googleAuthProvider: GoogleAuthorizationProvider = WebGoogleAuthorizationProvider(),
        appleAuthProvider: AppleWebAuthorizationProvider = WebAppleAuthorizationProvider()
    ) {
        self.session = session
        self.tokens = tokens
        self.baseURL = baseURL
        self.googleAuthProvider = googleAuthProvider
        self.appleAuthProvider = appleAuthProvider
    }

    /// The persisted session, or `nil` when signed out.
    var currentSession: AuthSession? { tokens.load() }

    // MARK: - Google (fully built + unit-tested)

    /// Drives the Google PKCE flow end-to-end:
    /// 1. generate PKCE, build the authorization URL,
    /// 2. get the `code` from the loopback redirect,
    /// 3. exchange `code` + `code_verifier` at Google's token endpoint → id_token,
    /// 4. POST the id_token to `/auth/google` → our session,
    /// 5. store both tokens in the Keychain.
    @discardableResult
    func signInWithGoogle() async throws -> AuthSession {
        let pkce = PKCE()
        // The redirect_uri isn't known until the loopback listener binds a port,
        // so the provider builds the authorize URL via this closure and hands the
        // chosen redirect_uri back for the token exchange (they must match).
        let (code, redirectURI) = try await googleAuthProvider.authorizationCode(
            expectedState: pkce.state,
            buildAuthorizationURL: { redirectURI in
                Self.googleAuthorizationURL(pkce: pkce, redirectURI: redirectURI)
            }
        )
        let idToken = try await exchangeGoogleCode(code, verifier: pkce.codeVerifier, redirectURI: redirectURI)
        let session = try await postSignIn(
            path: "/auth/google",
            body: GoogleSignInRequest(idToken: idToken)
        )
        try tokens.save(session)
        return session
    }

    /// Builds the Google authorization URL (PKCE `S256`) for the given loopback
    /// `redirectURI`. Internal for tests.
    static func googleAuthorizationURL(pkce: PKCE, redirectURI: String) -> URL {
        var components = URLComponents(url: AuthConfig.googleAuthorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AuthConfig.googleClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AuthConfig.googleScope),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return components.url!
    }

    /// Builds the Google `POST /token` PKCE-exchange request. `redirectURI` must be
    /// the exact loopback URI used in the authorize request. Internal for tests.
    static func googleTokenExchangeRequest(code: String, verifier: String, redirectURI: String) -> URLRequest {
        var request = URLRequest(url: AuthConfig.googleTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id": AuthConfig.googleClientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        request.httpBody = Data(Self.formEncode(form).utf8)
        return request
    }

    private func exchangeGoogleCode(_ code: String, verifier: String, redirectURI: String) async throws -> String {
        let request = Self.googleTokenExchangeRequest(code: code, verifier: verifier, redirectURI: redirectURI)
        let (data, response) = try await sessionData(for: request)
        try Self.ensure2xx(response)
        guard let decoded = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data) else {
            throw AuthError.decoding
        }
        return decoded.idToken
    }

    // MARK: - Apple (web flow — system browser, NO native entitlement)

    /// Drives Sign in with Apple entirely through the browser:
    /// 1. generate a random `state`, build Apple's `/auth/authorize` URL,
    /// 2. open it in the browser (via `WebAuthRouter`); it follows Apple → our
    ///    backend callback → the `translator-everywhere://apple-callback?...` redirect,
    /// 3. parse the callback (validate `state`, extract `session`+`refresh`),
    /// 4. store both tokens in the Keychain.
    ///
    /// Because the backend does the code→id_token exchange and mints the session,
    /// the app needs NO `com.apple.developer.applesignin` entitlement — which is
    /// what lets it ship signed with a plain Developer ID, no provisioning profile.
    @discardableResult
    func signInWithApple() async throws -> AuthSession {
        let state = PKCE.randomURLSafeToken(byteCount: 16)
        let authURL = Self.appleAuthorizationURL(state: state)
        let callback = try await appleAuthProvider.callbackURL(
            authorizationURL: authURL,
            callbackScheme: AuthConfig.appleCallbackScheme
        )
        let session = try Self.appleSession(from: callback, expectedState: state)
        try tokens.save(session)
        return session
    }

    /// Builds Apple's web authorization URL. Apple requires `response_mode=form_post`
    /// whenever a scope (name/email) is requested — `query` is rejected with
    /// `invalid_request`. Apple form-POSTs the `code` to the backend callback (which
    /// handles GET+POST), and the backend hands back via the `translator-everywhere://`
    /// redirect that `WebAuthRouter` captures. Internal for tests.
    static func appleAuthorizationURL(state: String) -> URL {
        var components = URLComponents(url: AuthConfig.appleAuthorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AuthConfig.appleServicesID),
            URLQueryItem(name: "redirect_uri", value: AuthConfig.appleRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "response_mode", value: "form_post"),
            URLQueryItem(name: "scope", value: AuthConfig.appleScope),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// Parses the backend's hand-back redirect
    /// `translator-everywhere://apple-callback?session=&refresh=&state=` into an
    /// `AuthSession`. Validates `state` (CSRF guard), surfaces an `?error=`, and
    /// derives the display user from the session JWT's payload. Internal for tests.
    static func appleSession(from url: URL, expectedState: String) throws -> AuthSession {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AuthError.providerResponseInvalid
        }
        let items = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        // An explicit backend error wins, but still guard state to avoid acting on
        // a spoofed callback.
        guard items["state"] == expectedState else {
            throw AuthError.providerResponseInvalid
        }
        if let error = items["error"], !error.isEmpty {
            throw AuthError.providerResponseInvalid
        }
        guard let sessionJWT = items["session"], !sessionJWT.isEmpty,
              let refreshToken = items["refresh"], !refreshToken.isEmpty
        else {
            throw AuthError.providerResponseInvalid
        }
        let user = Self.appleUser(fromSessionJWT: sessionJWT)
        return AuthSession(sessionJWT: sessionJWT, refreshToken: refreshToken, user: user)
    }

    /// Best-effort display user from the session JWT payload (`sub`/`email`). The
    /// callback carries no user object, so we read what the backend already signed
    /// into the JWT; an opaque/undecodable token still yields a valid Apple user.
    static func appleUser(fromSessionJWT jwt: String) -> AuthUser {
        let claims = decodeJWTPayload(jwt)
        let id = (claims["sub"] as? String) ?? (claims["user_id"] as? String) ?? ""
        let email = claims["email"] as? String
        return AuthUser(id: id, email: email, provider: .apple)
    }

    /// Decodes a JWT's base64url payload to a claims dictionary. Returns `[:]` for
    /// anything that isn't a well-formed three-part JWT (the session still works;
    /// only the display name/email is best-effort).
    static func decodeJWTPayload(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return [:] }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Restore base64 padding stripped by base64url.
        let padding = base64.count % 4
        if padding != 0 { base64 += String(repeating: "=", count: 4 - padding) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return json
    }

    // MARK: - Refresh / sign-out

    /// Swaps a valid refresh token for a fresh access JWT (`/auth/refresh`) and
    /// persists it. Returns the new JWT. On failure throws `.refreshFailed` so
    /// the caller drops to signed-out without losing the local notebook.
    @discardableResult
    func refreshSession() async throws -> String {
        guard let current = tokens.load() else { throw AuthError.notSignedIn }
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RefreshRequest(refreshToken: current.refreshToken))

        do {
            let (data, response) = try await sessionData(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw AuthError.refreshFailed
            }
            guard let decoded = try? JSONDecoder().decode(RefreshResponse.self, from: data) else {
                throw AuthError.refreshFailed
            }
            try tokens.updateSessionJWT(decoded.sessionJWT)
            return decoded.sessionJWT
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.refreshFailed
        }
    }

    /// Signs out: best-effort server revoke (`/auth/signout`) then clears the
    /// Keychain tokens. The local notebook stays intact (DESIGN §2e).
    func signOut() async {
        if let current = tokens.load() {
            var request = URLRequest(url: baseURL.appendingPathComponent("auth/signout"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(current.sessionJWT)", forHTTPHeaderField: "Authorization")
            _ = try? await sessionData(for: request)
        }
        try? tokens.clear()
    }

    /// Deletes the account + all cloud rows (`DELETE /account`), then clears
    /// local tokens. The local notebook is kept (the user can re-sync later from
    /// scratch). Throws on a non-2xx so the UI can surface failure.
    func deleteAccount() async throws {
        guard let current = tokens.load() else { throw AuthError.notSignedIn }
        var request = URLRequest(url: baseURL.appendingPathComponent("account"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(current.sessionJWT)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await sessionData(for: request)
        try Self.ensure2xx(response)
        try? tokens.clear()
    }

    // MARK: - Backend sign-in POST

    private func postSignIn<Body: Encodable>(path: String, body: Body) async throws -> AuthSession {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await sessionData(for: request)
        try Self.ensure2xx(response)
        guard let decoded = try? JSONDecoder().decode(SessionResponse.self, from: data) else {
            throw AuthError.decoding
        }
        return AuthSession(
            sessionJWT: decoded.sessionJWT,
            refreshToken: decoded.refreshToken,
            user: decoded.user
        )
    }

    // MARK: - Helpers

    private func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw AuthError.transport
        }
    }

    private static func ensure2xx(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw AuthError.transport }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.server(status: http.statusCode)
        }
    }

    /// `application/x-www-form-urlencoded` body, stable key order for testability.
    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.keys.sorted().map { key in
            let value = fields[key] ?? ""
            let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(escaped)"
        }.joined(separator: "&")
    }
}
