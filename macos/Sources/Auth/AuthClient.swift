import AuthenticationServices
import Foundation

/// Acquires a Google authorization `code` by driving the system browser. The
/// real implementation is `ASWebAuthenticationSession`; tests inject a stub so
/// the PKCE token-exchange + backend POST can run headlessly.
protocol GoogleAuthorizationProvider: Sendable {
    /// Presents the consent UI for `authorizationURL` and returns the `code`
    /// from the loopback redirect, validating `state`.
    func authorizationCode(authorizationURL: URL, redirectScheme: String, expectedState: String) async throws -> String
}

/// Acquires an Apple identity token via `ASAuthorizationController`. Injected so
/// the request-builder + backend POST can be smoke-tested; the real controller
/// can't run headlessly (and needs code-signing at runtime — slice 8).
protocol AppleIdentityProvider: Sendable {
    /// Runs the native Sign in with Apple sheet and returns the identity-token
    /// JWT string.
    func identityToken() async throws -> String
}

/// Sign-in via AuthenticationServices (TECH §8.6).
///
/// Apple via `ASAuthorizationController`; Google via `ASWebAuthenticationSession`
/// + PKCE. Both end the same way: get a provider identity token on-device, POST
/// it to our `/auth/<provider>` endpoint, receive our session JWT + refresh,
/// store both in the Keychain, and return the `AuthSession`. The app works fully
/// without ever signing in — this only enables cross-Mac sync.
final class AuthClient {

    private let session: URLSession
    private let tokens: TokenStore
    private let googleAuthProvider: GoogleAuthorizationProvider
    private let appleProvider: AppleIdentityProvider
    private let baseURL: URL

    init(
        session: URLSession = .shared,
        tokens: TokenStore = TokenStore(),
        baseURL: URL = AuthConfig.backendBaseURL,
        googleAuthProvider: GoogleAuthorizationProvider = WebGoogleAuthorizationProvider(),
        appleProvider: AppleIdentityProvider = ControllerAppleIdentityProvider()
    ) {
        self.session = session
        self.tokens = tokens
        self.baseURL = baseURL
        self.googleAuthProvider = googleAuthProvider
        self.appleProvider = appleProvider
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
        let authURL = Self.googleAuthorizationURL(pkce: pkce)
        let code = try await googleAuthProvider.authorizationCode(
            authorizationURL: authURL,
            redirectScheme: AuthConfig.googleRedirectScheme,
            expectedState: pkce.state
        )
        let idToken = try await exchangeGoogleCode(code, verifier: pkce.codeVerifier)
        let session = try await postSignIn(
            path: "/auth/google",
            body: GoogleSignInRequest(idToken: idToken)
        )
        try tokens.save(session)
        return session
    }

    /// Builds the Google authorization URL (PKCE `S256`). Internal for tests.
    static func googleAuthorizationURL(pkce: PKCE) -> URL {
        var components = URLComponents(url: AuthConfig.googleAuthorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AuthConfig.googleClientID),
            URLQueryItem(name: "redirect_uri", value: AuthConfig.googleRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AuthConfig.googleScope),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return components.url!
    }

    /// Builds the Google `POST /token` PKCE-exchange request. Internal for tests.
    static func googleTokenExchangeRequest(code: String, verifier: String) -> URLRequest {
        var request = URLRequest(url: AuthConfig.googleTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id": AuthConfig.googleClientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": AuthConfig.googleRedirectURI,
        ]
        request.httpBody = Data(Self.formEncode(form).utf8)
        return request
    }

    private func exchangeGoogleCode(_ code: String, verifier: String) async throws -> String {
        let request = Self.googleTokenExchangeRequest(code: code, verifier: verifier)
        let (data, response) = try await sessionData(for: request)
        try Self.ensure2xx(response)
        guard let decoded = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data) else {
            throw AuthError.decoding
        }
        return decoded.idToken
    }

    // MARK: - Apple (compiles now; runtime needs code-signing — slice 8)

    /// Drives Sign in with Apple, then the same backend exchange as Google.
    ///
    /// NOTE: `ASAuthorizationController` (in `ControllerAppleIdentityProvider`)
    /// requires the app to be code-signed with the `applesignin` entitlement, so
    /// this WON'T succeed at runtime until slice 8. The structure (identity token
    /// → `POST /auth/apple` → store tokens) is identical to Google and IS
    /// unit-tested via an injected `AppleIdentityProvider`.
    @discardableResult
    func signInWithApple() async throws -> AuthSession {
        let identityToken = try await appleProvider.identityToken()
        let session = try await postSignIn(
            path: "/auth/apple",
            body: AppleSignInRequest(identityToken: identityToken)
        )
        try tokens.save(session)
        return session
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
