import Foundation
import Testing
@testable import Translator_Everywhere

/// A Google authorization stub that returns a canned `code` without any UI.
private struct StubGoogleAuth: GoogleAuthorizationProvider {
    let code: String
    func authorizationCode(authorizationURL: URL, redirectScheme: String, expectedState: String) async throws -> String {
        code
    }
}

/// A stub Apple identity provider returning a canned identity-token JWT.
private struct StubAppleProvider: AppleIdentityProvider {
    let token: String
    func identityToken() async throws -> String { token }
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
        let url = AuthClient.googleAuthorizationURL(pkce: pkce)
        let items = Dictionary(
            uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value) }
        )
        #expect(items["client_id"] == AuthConfig.googleClientID)
        #expect(items["response_type"] == "code")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == pkce.codeChallenge)
        #expect(items["state"] == "state-xyz")
        #expect((items["scope"] ?? nil)?.contains("openid") == true)
    }

    @Test("Google token-exchange request posts form-encoded code + verifier")
    func googleTokenExchangeRequest() {
        let request = AuthClient.googleTokenExchangeRequest(code: "auth-code-1", verifier: "verifier-abc")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(data: request.httpBody!, encoding: .utf8)!
        #expect(body.contains("code=auth-code-1"))
        #expect(body.contains("code_verifier=verifier-abc"))
        #expect(body.contains("grant_type=authorization_code"))
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
            appleProvider: StubAppleProvider(token: "x")
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
            appleProvider: StubAppleProvider(token: "x")
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
            appleProvider: StubAppleProvider(token: "x")
        )
        await #expect(throws: AuthError.self) { _ = try await client.signInWithGoogle() }
        #expect(tokens.load() == nil)
    }

    // MARK: - Apple (headless smoke — ASAuthorization can't run here)

    @Test("Apple sign-in posts identity_token to /auth/apple and stores tokens")
    func appleSignInPostsIdentityToken() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        var path: String?
        var body: Data?
        MockURLProtocol.handler = { request in
            path = request.url?.path
            body = MockURLProtocol.lastBody
            return (self.sessionJSON(provider: "apple"), MockURLProtocol.okResponse(for: request))
        }
        let tokens = makeTokens()
        let client = AuthClient(
            session: MockURLProtocol.makeSession(),
            tokens: tokens,
            baseURL: baseURL,
            googleAuthProvider: StubGoogleAuth(code: "x"),
            appleProvider: StubAppleProvider(token: "apple.identity.jwt")
        )
        let result = try await client.signInWithApple()

        #expect(path == "/auth/apple")
        let json = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
        #expect(json?["identity_token"] as? String == "apple.identity.jwt")
        #expect(result.user.provider == .apple)
        #expect(tokens.load()?.sessionJWT == "sess.jwt.token")
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
