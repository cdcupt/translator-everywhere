import Foundation
import Testing
@testable import Translator_Everywhere

private struct StubGoogleAuth: GoogleAuthorizationProvider {
    let code: String
    func authorizationCode(authorizationURL: URL, redirectScheme: String, expectedState: String) async throws -> String { code }
}
private struct StubApple: AppleIdentityProvider {
    let token: String
    func identityToken() async throws -> String { token }
}

@MainActor
@Suite("AccountViewModel — signed-out ↔ signed-in state machine")
struct AccountViewModelTests {

    private let baseURL = URL(string: "https://api.translator.daichenlab.com")!

    private func makeTokens() -> TokenStore {
        let id = UUID().uuidString
        return TokenStore(
            keychain: KeychainStore(service: "com.cdcupt.translator-everywhere.tests-\(id)"),
            defaults: UserDefaults(suiteName: "account-tests-\(id)")!
        )
    }

    private func sessionJSON(provider: String = "google") -> Data {
        Data(#"{"session_jwt":"j","refresh_token":"r","user":{"id":"u","email":"e@x.com","provider":"\#(provider)"}}"#.utf8)
    }

    @Test("starts signed-out when no session is stored")
    func startsSignedOut() {
        let client = AuthClient(session: MockURLProtocol.makeSession(), tokens: makeTokens(), baseURL: baseURL)
        let model = AccountViewModel(auth: client)
        #expect(model.isSignedIn == false)
        #expect(model.phase == .signedOut)
    }

    @Test("starts signed-in when a session already exists")
    func startsSignedIn() throws {
        let tokens = makeTokens()
        try tokens.save(AuthSession(sessionJWT: "j", refreshToken: "r",
                                    user: AuthUser(id: "u", email: "e@x.com", provider: .apple)))
        let client = AuthClient(session: MockURLProtocol.makeSession(), tokens: tokens, baseURL: baseURL)
        let model = AccountViewModel(auth: client)
        #expect(model.isSignedIn)
        #expect(model.currentUser?.provider == .apple)
    }

    @Test("Google sign-in transitions to signed-in and fires the sync hook")
    func googleSignInTransitions() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { request in
            let host = request.url?.host ?? ""
            if host.contains("googleapis") {
                return (Data(#"{"id_token":"t"}"#.utf8), MockURLProtocol.okResponse(for: request))
            }
            return (self.sessionJSON(), MockURLProtocol.okResponse(for: request))
        }
        let client = AuthClient(
            session: MockURLProtocol.makeSession(), tokens: makeTokens(), baseURL: baseURL,
            googleAuthProvider: StubGoogleAuth(code: "c"), appleProvider: StubApple(token: "x")
        )
        let syncDate = Date(timeIntervalSince1970: 1_700_000_000)
        var hookFired = false
        let model = AccountViewModel(auth: client, onSignedIn: {
            hookFired = true
            return syncDate
        })

        await model.signInWithGoogle()

        #expect(model.isSignedIn)
        #expect(hookFired)
        #expect(model.lastSyncedAt == syncDate)
    }

    @Test("sign-out returns to signed-out and clears tokens")
    func signOutClears() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let tokens = makeTokens()
        try tokens.save(AuthSession(sessionJWT: "j", refreshToken: "r",
                                    user: AuthUser(id: "u", email: nil, provider: .google)))
        MockURLProtocol.handler = { request in (Data(), MockURLProtocol.okResponse(for: request)) }
        let client = AuthClient(session: MockURLProtocol.makeSession(), tokens: tokens, baseURL: baseURL)
        var signedOutCalled = false
        let model = AccountViewModel(auth: client, onSignedOut: { signedOutCalled = true })
        #expect(model.isSignedIn)

        await model.signOut()

        #expect(model.phase == .signedOut)
        #expect(signedOutCalled)
        #expect(tokens.load() == nil)
    }

    @Test("delete-account calls the endpoint and returns to signed-out")
    func deleteAccountTransitions() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let tokens = makeTokens()
        try tokens.save(AuthSession(sessionJWT: "the.jwt", refreshToken: "r",
                                    user: AuthUser(id: "u", email: nil, provider: .google)))
        var hitDelete = false
        MockURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" { hitDelete = true }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let client = AuthClient(session: MockURLProtocol.makeSession(), tokens: tokens, baseURL: baseURL)
        let model = AccountViewModel(auth: client)
        model.isConfirmingDelete = true

        await model.deleteAccount()

        #expect(hitDelete)
        #expect(model.phase == .signedOut)
        #expect(model.isConfirmingDelete == false)
        #expect(tokens.load() == nil)
    }

    @Test("a failed Google sign-in surfaces an error phase")
    func signInErrorPhase() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { request in
            let host = request.url?.host ?? ""
            if host.contains("googleapis") {
                return (Data(#"{"id_token":"t"}"#.utf8), MockURLProtocol.okResponse(for: request))
            }
            return (Data("nope".utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let client = AuthClient(
            session: MockURLProtocol.makeSession(), tokens: makeTokens(), baseURL: baseURL,
            googleAuthProvider: StubGoogleAuth(code: "c"), appleProvider: StubApple(token: "x")
        )
        let model = AccountViewModel(auth: client)
        await model.signInWithGoogle()

        if case .error = model.phase { } else { Issue.record("expected .error phase, got \(model.phase)") }
        #expect(model.isSignedIn == false)
    }
}
