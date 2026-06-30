import Foundation
import Testing
@testable import Translator_Everywhere

/// A Google authorization stub that returns a canned `code` + loopback redirect
/// URI without any UI. Exercises `buildAuthorizationURL` to mirror the real flow.
private struct StubGoogleAuth: GoogleAuthorizationProvider {
    let code: String
    var redirectURI = "http://127.0.0.1:0/oauth2redirect"
    func authorizationCode(
        expectedState: String,
        buildAuthorizationURL: (_ redirectURI: String) -> URL
    ) async throws -> (code: String, redirectURI: String) {
        _ = buildAuthorizationURL(redirectURI)
        return (code, redirectURI)
    }
}

/// A stub Apple web-auth provider returning a canned backend callback URL,
/// echoing the `state` from the authorize URL so `state` validation passes.
private struct StubAppleWebAuth: AppleWebAuthorizationProvider {
    /// `{state}` in this template is replaced with the live state at call time.
    let callbackTemplate: String
    func callbackURL(authorizationURL: URL, callbackScheme: String) async throws -> URL {
        let state = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        return URL(string: callbackTemplate.replacingOccurrences(of: "{state}", with: state))!
    }
}

@Suite("AuthClient — Google PKCE, Apple, refresh, delete")
struct AuthClientTests {

    private let baseURL = URL(string: "https://api.translator.daichenlab.com")!

    /// A TokenStore backed by a unique Keychain service + UserDefaults suite so
    /// tests never collide with each other or the real app.
    private func makeTokens() -> TokenStore {
        let id = UUID().uuidString
        let keychain = KeychainStore(service: "com.cdcupt.translator-everywhere.tests-\(id)")
        let defaults = UserDefaults(suiteName: "auth-tests-\(id)")!
        return TokenStore(keychain: keychain, defaults: defaults)
    }

    private func sessionJSON(email: String = "erik@example.com", provider: String = "google") -> Data {
        Data("""
        {"session_jwt":"sess.jwt.token","refresh_token":"refresh.token.123",
         "user":{"id":"u_1","email":"\(email)","provider":"\(provider)"}}
        """.utf8)
    }

    // MARK: - Google PKCE

    @Test("Google authorization URL carries client_id, S256 challenge, state")
    func googleAuthorizationURL() {
        let pkce = PKCE(codeVerifier: "verifier-abc", state: "state-xyz")
        let redirectURI = "http://127.0.0.1:51234/oauth2redirect"
        let url = AuthClient.googleAuthorizationURL(pkce: pkce, redirectURI: redirectURI)
        let items = Dictionary(
            uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value) }
        )
        #expect(items["client_id"] == AuthConfig.googleClientID)
        #expect(items["redirect_uri"] == redirectURI)
        #expect(items["response_type"] == "code")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == pkce.codeChallenge)
        #expect(items["state"] == "state-xyz")
        #expect((items["scope"] ?? nil)?.contains("openid") == true)
    }

    @Test("Google token-exchange request posts form-encoded code + verifier + redirect")
    func googleTokenExchangeRequest() {
        let redirectURI = "http://127.0.0.1:51234/oauth2redirect"
        let request = AuthClient.googleTokenExchangeRequest(
            code: "auth-code-1", verifier: "verifier-abc", redirectURI: redirectURI
        )
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(data: request.httpBody!, encoding: .utf8)!
        #expect(body.contains("code=auth-code-1"))
        #expect(body.contains("code_verifier=verifier-abc"))
        #expect(body.contains("grant_type=authorization_code"))
        // redirect_uri is percent-encoded in the form body.
        #expect(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A51234%2Foauth2redirect"))
        #expect(request.url == AuthConfig.googleTokenEndpoint)
    }

    @Test("Google sign-in exchanges code → id_token → session and stores both tokens")
    func googleSignInStoresTokens() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        // Two stops: Google token endpoint → id_token; our /auth/google → session.
        let googleToken = Data(#"{"id_token":"google.id.token","access_token":"a"}"#.utf8)
        let session = sessionJSON()
        MockURLProtocol.handler = { request in
            let host = request.url?.host ?? ""
            if host.contains("googleapis") {
                return (googleToken, MockURLProtocol.okResponse(for: request))
            }
            return (session, MockURLProtocol.okResponse(for: request))
        }

        let tokens = makeTokens()
        let client = AuthClient(
            session: MockURLProtocol.makeSession(),
            tokens: tokens,
            baseURL: baseURL,
            googleAuthProvider: StubGoogleAuth(code: "auth-code-1"),
            appleAuthProvider: StubAppleWebAuth(callbackTemplate: "translator-everywhere://apple-callback?session=s&refresh=r&state={state}")
        )

        let result = try await client.signInWithGoogle()

        #expect(result.sessionJWT == "sess.jwt.token")
        #expect(result.refreshToken == "refresh.token.123")
        #expect(result.user.provider == .google)
        // Persisted: a fresh load returns the same session.
        let loaded = tokens.load()
        #expect(loaded?.sessionJWT == "sess.jwt.token")
        #expect(loaded?.refreshToken == "refresh.token.123")
    }

    @Test("Google sign-in POSTs id_token to /auth/google")
    func googleSignInPostsIDToken() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let googleToken = Data(#"{"id_token":"google.id.token"}"#.utf8)
        let session = sessionJSON()
        var authPath: String?
        var authBody: Data?
        MockURLProtocol.handler = { request in
            let host = request.url?.host ?? ""
            if host.contains("googleapis") {
                return (googleToken, MockURLProtocol.okResponse(for: request))
            }
            authPath = request.url?.path
            authBody = MockURLProtocol.lastBody
            return (session, MockURLProtocol.okResponse(for: request))
        }

        let client = AuthClient(
            session: MockURLProtocol.makeSession(),
            tokens: makeTokens(),
            baseURL: baseURL,
            googleAuthProvider: StubGoogleAuth(code: "c"),
            appleAuthProvider: StubAppleWebAuth(callbackTemplate: "translator-everywhere://apple-callback?session=s&refresh=r&state={state}")
        )
        _ = try await client.signInWithGoogle()

        #expect(authPath == "/auth/google")
        let json = try JSONSerialization.jsonObject(with: authBody ?? Data()) as? [String: Any]
        #expect(json?["id_token"] as? String == "google.id.token")
    }

    @Test("Backend 500 on sign-in surfaces .server and stores nothing")
    func googleSignInServerError() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { request in
            let host = request.url?.host ?? ""
            if host.contains("googleapis") {
                return (Data(#"{"id_token":"t"}"#.utf8), MockURLProtocol.okResponse(for: request))
            }
            return (Data("oops".utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let tokens = makeTokens()
        let client = AuthClient(
            session: MockURLProtocol.makeSession(),
            tokens: tokens,
            baseURL: baseURL,
            googleAuthProvider: StubGoogleAuth(code: "c"),
            appleAuthProvider: StubAppleWebAuth(callbackTemplate: "translator-everywhere://apple-callback?session=s&refresh=r&state={state}")
        )
        await #expect(throws: AuthError.self) { _ = try await client.signInWithGoogle() }
        #expect(tokens.load() == nil)
    }

    // MARK: - Apple (WEB flow — ASWebAuthenticationSession, no native entitlement)

    /// Builds a base64url JWT with the given payload (header/signature are dummy)
    /// so `AuthClient.appleUser(fromSessionJWT:)` has real claims to decode.
    private func makeJWT(payload: [String: Any]) -> String {
        let body = try! JSONSerialization.data(withJSONObject: payload)
        let header = PKCE.base64URLEncode(Data(#"{"alg":"none"}"#.utf8))
        let claims = PKCE.base64URLEncode(body)
        return "\(header).\(claims).sig"
    }

    @Test("Apple authorize URL carries the Services ID client_id, redirect, scope, state")
    func appleAuthorizationURL() {
        let url = AuthClient.appleAuthorizationURL(state: "state-123")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value) })
        #expect(comps.host == "appleid.apple.com")
        #expect(comps.path == "/auth/authorize")
        #expect(items["client_id"] == AuthConfig.appleServicesID)
        #expect(items["client_id"] == "com.cdcupt.translator-everywhere.web")
        #expect(items["redirect_uri"] == AuthConfig.appleRedirectURI)
        #expect(items["redirect_uri"] == "https://api.translator.daichenlab.com/auth/apple/callback")
        #expect(items["response_type"] == "code")
        #expect(items["response_mode"] == "form_post")
        #expect((items["scope"] ?? nil) == "name email")
        #expect(items["state"] == "state-123")
    }

    @Test("Apple web sign-in parses the backend callback and stores session + refresh (no backend POST)")
    func appleWebSignInStoresTokens() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        // The web flow does NOT hit our backend from the app — the backend already
        // minted the tokens before redirecting. Any network call here is a bug.
        var sawNetwork = false
        MockURLProtocol.handler = { request in
            sawNetwork = true
            return (Data(), MockURLProtocol.okResponse(for: request))
        }
        let jwt = makeJWT(payload: ["sub": "apple_user_1", "email": "erik@icloud.com"])
        let tokens = makeTokens()
        let client = AuthClient(
            session: MockURLProtocol.makeSession(),
            tokens: tokens,
            baseURL: baseURL,
            googleAuthProvider: StubGoogleAuth(code: "x"),
            appleAuthProvider: StubAppleWebAuth(
                callbackTemplate: "translator-everywhere://apple-callback?session=\(jwt)&refresh=apple.refresh.9&state={state}"
            )
        )

        let result = try await client.signInWithApple()

        #expect(sawNetwork == false)
        #expect(result.sessionJWT == jwt)
        #expect(result.refreshToken == "apple.refresh.9")
        #expect(result.user.provider == .apple)
        #expect(result.user.id == "apple_user_1")
        #expect(result.user.email == "erik@icloud.com")
        // Persisted: a fresh load returns the same session.
        #expect(tokens.load()?.sessionJWT == jwt)
        #expect(tokens.load()?.refreshToken == "apple.refresh.9")
    }

    @Test("Apple callback parsing extracts session + refresh and accepts a matching state")
    func appleCallbackExtractsTokens() throws {
        let url = URL(string: "translator-everywhere://apple-callback?session=sess.jwt&refresh=ref.tok&state=abc")!
        let session = try AuthClient.appleSession(from: url, expectedState: "abc")
        #expect(session.sessionJWT == "sess.jwt")
        #expect(session.refreshToken == "ref.tok")
        #expect(session.user.provider == .apple)
    }

    @Test("Apple callback rejects a mismatched state (CSRF guard)")
    func appleCallbackRejectsStateMismatch() {
        let url = URL(string: "translator-everywhere://apple-callback?session=s&refresh=r&state=evil")!
        #expect(throws: AuthError.providerResponseInvalid) {
            _ = try AuthClient.appleSession(from: url, expectedState: "expected")
        }
    }

    @Test("Apple callback with ?error= surfaces an auth error")
    func appleCallbackErrorSurfaces() {
        let url = URL(string: "translator-everywhere://apple-callback?error=user_cancelled&state=abc")!
        #expect(throws: AuthError.providerResponseInvalid) {
            _ = try AuthClient.appleSession(from: url, expectedState: "abc")
        }
    }

    @Test("Apple web sign-in surfaces the ?error= path through the full flow")
    func appleWebSignInErrorPath() async {
        let tokens = makeTokens()
        let client = AuthClient(
            session: MockURLProtocol.makeSession(),
            tokens: tokens,
            baseURL: baseURL,
            googleAuthProvider: StubGoogleAuth(code: "x"),
            appleAuthProvider: StubAppleWebAuth(
                callbackTemplate: "translator-everywhere://apple-callback?error=access_denied&state={state}"
            )
        )
        await #expect(throws: AuthError.providerResponseInvalid) {
            _ = try await client.signInWithApple()
        }
        #expect(tokens.load() == nil)
    }

    @Test("Apple user falls back to an empty id / nil email for an opaque session token")
    func appleUserOpaqueToken() {
        let user = AuthClient.appleUser(fromSessionJWT: "not-a-jwt")
        #expect(user.provider == .apple)
        #expect(user.id == "")
        #expect(user.email == nil)
    }

    // MARK: - Refresh / sign-out / delete

    @Test("refresh swaps in a new access JWT, keeping the refresh token")
    func refreshUpdatesAccessJWT() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let tokens = makeTokens()
        try tokens.save(AuthSession(
            sessionJWT: "old.jwt", refreshToken: "refresh.123",
            user: AuthUser(id: "u", email: "e@x.com", provider: .google)
        ))
        MockURLProtocol.handler = { request in
            (Data(#"{"session_jwt":"new.jwt"}"#.utf8), MockURLProtocol.okResponse(for: request))
        }
        let client = AuthClient(session: MockURLProtocol.makeSession(), tokens: tokens, baseURL: baseURL)
        let fresh = try await client.refreshSession()

        #expect(fresh == "new.jwt")
        #expect(tokens.load()?.sessionJWT == "new.jwt")
        #expect(tokens.load()?.refreshToken == "refresh.123")
    }

    @Test("refresh failure throws .refreshFailed")
    func refreshFailure() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let tokens = makeTokens()
        try tokens.save(AuthSession(
            sessionJWT: "old", refreshToken: "r",
            user: AuthUser(id: "u", email: nil, provider: .apple)
        ))
        MockURLProtocol.handler = { request in
            (Data("no".utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        let client = AuthClient(session: MockURLProtocol.makeSession(), tokens: tokens, baseURL: baseURL)
        await #expect(throws: AuthError.refreshFailed) { _ = try await client.refreshSession() }
    }

    @Test("sign-out clears Keychain tokens (notebook untouched)")
    func signOutClearsTokens() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let tokens = makeTokens()
        try tokens.save(AuthSession(
            sessionJWT: "j", refreshToken: "r",
            user: AuthUser(id: "u", email: nil, provider: .google)
        ))
        MockURLProtocol.handler = { request in (Data(), MockURLProtocol.okResponse(for: request)) }
        let client = AuthClient(session: MockURLProtocol.makeSession(), tokens: tokens, baseURL: baseURL)

        await client.signOut()
        #expect(tokens.load() == nil)
    }

    @Test("delete-account calls DELETE /account with Bearer and clears tokens")
    func deleteAccountCallsEndpoint() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let tokens = makeTokens()
        try tokens.save(AuthSession(
            sessionJWT: "the.jwt", refreshToken: "r",
            user: AuthUser(id: "u", email: nil, provider: .google)
        ))
        var method: String?
        var auth: String?
        var path: String?
        MockURLProtocol.handler = { request in
            method = request.httpMethod
            auth = request.value(forHTTPHeaderField: "Authorization")
            path = request.url?.path
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let client = AuthClient(session: MockURLProtocol.makeSession(), tokens: tokens, baseURL: baseURL)
        try await client.deleteAccount()

        #expect(method == "DELETE")
        #expect(path == "/account")
        #expect(auth == "Bearer the.jwt")
        #expect(tokens.load() == nil)
    }
}
