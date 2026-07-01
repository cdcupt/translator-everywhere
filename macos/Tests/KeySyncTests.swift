import Foundation
import Testing
@testable import Translator_Everywhere

// MARK: - Test doubles

/// An in-memory `SecretSyncClientProtocol` — records uploads/deletes and returns
/// a canned fetch result (or throws), so the branch logic is exercised without
/// the network.
private actor MockSecretClient: SecretSyncClientProtocol {
    private(set) var uploads: [String] = []
    private(set) var deleteCount = 0
    private var fetchResult: SecretFetchResult
    private var fetchError: Error?
    private var uploadError: Error?

    init(
        fetchResult: SecretFetchResult = .notFound,
        fetchError: Error? = nil,
        uploadError: Error? = nil
    ) {
        self.fetchResult = fetchResult
        self.fetchError = fetchError
        self.uploadError = uploadError
    }

    func setFetchError(_ error: Error) { fetchError = error }

    func upload(key: String) async throws {
        if let uploadError { throw uploadError }
        uploads.append(key)
    }

    func fetch() async throws -> SecretFetchResult {
        if let fetchError { throw fetchError }
        return fetchResult
    }

    func delete() async throws { deleteCount += 1 }
}

/// A configurable `SyncAuthProvider` for `SecretSyncClient`'s 401→refresh path.
private struct FakeSecretAuth: SyncAuthProvider {
    let token: String?
    let refreshed: String?
    func currentAccessToken() async -> String? { token }
    func refreshAccessToken() async -> String? { refreshed }
}

// MARK: - KeySyncService (the toggle + restore branch)

@Suite("KeySyncService — enable/disable, auto-restore, never-wipe/don't-clobber")
@MainActor
struct KeySyncServiceTests {

    /// A service over a test-scoped Keychain (unique service) and an isolated
    /// `UserDefaults` suite, plus a fixed sign-in state.
    private func makeService(
        mock: MockSecretClient,
        signedIn: Bool,
        enabled: Bool = false
    ) -> (KeySyncService, KeychainStore, String, SettingsStore) {
        let service = "com.cdcupt.translator-everywhere.tests-\(UUID().uuidString)"
        let keychain = KeychainStore(service: service)
        let suite = "KeySyncTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults)
        settings.keySyncEnabled = enabled
        let svc = KeySyncService(
            client: mock, keychain: keychain, settings: settings, isSignedIn: { signedIn }
        )
        return (svc, keychain, KeychainStore.openAIKeyAccount, settings)
    }

    @Test("enable uploads the key once and arms the flag")
    func enableUploadsOnce() async {
        let mock = MockSecretClient()
        let (svc, kc, acct, settings) = makeService(mock: mock, signedIn: true)
        defer { try? kc.delete(acct) }

        await svc.enable(key: "sk-abc")

        #expect(await mock.uploads == ["sk-abc"])
        #expect(svc.isEnabled)
        #expect(settings.keySyncEnabled)
        if case .synced = svc.state {} else { Issue.record("expected .synced, got \(svc.state)") }
    }

    @Test("editing the key while sync is ON re-uploads")
    func editWhileOnReuploads() async {
        let mock = MockSecretClient()
        let (svc, kc, acct, _) = makeService(mock: mock, signedIn: true)
        defer { try? kc.delete(acct) }

        await svc.enable(key: "sk-1")
        await svc.uploadIfEnabled(key: "sk-2")

        #expect(await mock.uploads == ["sk-1", "sk-2"])
    }

    @Test("clearing the field while ON neither uploads empty nor deletes (R2)")
    func clearingFieldIsNoOp() async {
        let mock = MockSecretClient()
        let (svc, kc, acct, _) = makeService(mock: mock, signedIn: true)
        defer { try? kc.delete(acct) }

        await svc.enable(key: "sk-1")
        await svc.uploadIfEnabled(key: "   ")

        #expect(await mock.uploads == ["sk-1"])
        #expect(await mock.deleteCount == 0)
    }

    @Test("disable deletes the server copy and keeps the local key")
    func disableDeletesKeepsLocal() async throws {
        let mock = MockSecretClient()
        let (svc, kc, acct, settings) = makeService(mock: mock, signedIn: true)
        defer { try? kc.delete(acct) }
        try kc.set("sk-local", for: acct)

        await svc.enable(key: "sk-local")
        await svc.disable()

        #expect(await mock.deleteCount == 1)
        #expect(kc.string(for: acct) == "sk-local")
        #expect(!svc.isEnabled)
        #expect(!settings.keySyncEnabled)
    }

    @Test("auto-restore writes the key + shows the toast when the Keychain is empty")
    func autoRestoreWhenLocalEmpty() async {
        let mock = MockSecretClient(fetchResult: .found(key: "sk-server", updatedAt: Date()))
        let (svc, kc, acct, settings) = makeService(mock: mock, signedIn: true)
        defer { try? kc.delete(acct) }

        await svc.restoreAfterSignIn()

        #expect(kc.string(for: acct) == "sk-server")
        #expect(svc.showRestoredToast)
        #expect(svc.isEnabled)
        #expect(settings.keySyncEnabled)
    }

    @Test("restore never clobbers a different local key — it prompts instead")
    func dontClobberDifferentKey() async throws {
        let mock = MockSecretClient(fetchResult: .found(key: "sk-server", updatedAt: Date()))
        let (svc, kc, acct, _) = makeService(mock: mock, signedIn: true)
        defer { try? kc.delete(acct) }
        try kc.set("sk-local", for: acct)

        await svc.restoreAfterSignIn()

        #expect(kc.string(for: acct) == "sk-local")     // untouched
        #expect(svc.pendingConflict?.serverKey == "sk-server")
        #expect(!svc.showRestoredToast)
    }

    @Test("restore is a silent re-arm when the local key already matches")
    func sameKeyReArmsSilently() async throws {
        let mock = MockSecretClient(fetchResult: .found(key: "sk-same", updatedAt: Date()))
        let (svc, kc, acct, settings) = makeService(mock: mock, signedIn: true)
        defer { try? kc.delete(acct) }
        try kc.set("sk-same", for: acct)

        await svc.restoreAfterSignIn()

        #expect(kc.string(for: acct) == "sk-same")
        #expect(svc.pendingConflict == nil)
        #expect(!svc.showRestoredToast)
        #expect(settings.keySyncEnabled)
    }

    @Test("restore never wipes the local key on a 404 / empty server")
    func neverWipeOn404() async throws {
        let mock = MockSecretClient(fetchResult: .notFound)
        let (svc, kc, acct, settings) = makeService(mock: mock, signedIn: true)
        defer { try? kc.delete(acct) }
        try kc.set("sk-local", for: acct)

        await svc.restoreAfterSignIn()

        #expect(kc.string(for: acct) == "sk-local")
        #expect(!settings.keySyncEnabled)               // not armed by an empty server
    }

    @Test("restore never wipes the local key on a fetch error (e.g. 503)")
    func neverWipeOnFetchError() async throws {
        let mock = MockSecretClient()
        await mock.setFetchError(SyncError.server(status: 503))
        let (svc, kc, acct, _) = makeService(mock: mock, signedIn: true)
        defer { try? kc.delete(acct) }
        try kc.set("sk-local", for: acct)

        await svc.restoreAfterSignIn()

        #expect(kc.string(for: acct) == "sk-local")
    }

    @Test("empty/whitespace server key on an empty Keychain is a no-op (never write)",
          arguments: ["", "   "])
    func emptyServerKeyLocalEmptyNoOp(serverKey: String) async {
        let mock = MockSecretClient(fetchResult: .found(key: serverKey, updatedAt: Date()))
        let (svc, kc, acct, settings) = makeService(mock: mock, signedIn: true)
        defer { try? kc.delete(acct) }

        await svc.restoreAfterSignIn()

        #expect(kc.string(for: acct) == nil)          // never written
        #expect(svc.pendingConflict == nil)
        #expect(!svc.showRestoredToast)
        #expect(!settings.keySyncEnabled)             // not armed
    }

    @Test("empty/whitespace server key never raises a conflict against a different local key",
          arguments: ["", "   "])
    func emptyServerKeyDifferentLocalNoConflict(serverKey: String) async throws {
        let mock = MockSecretClient(fetchResult: .found(key: serverKey, updatedAt: Date()))
        let (svc, kc, acct, settings) = makeService(mock: mock, signedIn: true)
        defer { try? kc.delete(acct) }
        try kc.set("sk-local", for: acct)

        await svc.restoreAfterSignIn()

        #expect(kc.string(for: acct) == "sk-local")   // local key untouched
        #expect(svc.pendingConflict == nil)           // no clobber prompt raised
        #expect(!svc.showRestoredToast)
        #expect(!settings.keySyncEnabled)
    }

    @Test("the toggle is disabled with a reason when signed out or when there is no key")
    func toggleDisabledReasons() {
        let signedOut = KeySyncService(client: MockSecretClient(), isSignedIn: { false })
        #expect(signedOut.syncDisabledReason(hasKey: true) != nil)

        let signedIn = KeySyncService(client: MockSecretClient(), isSignedIn: { true })
        #expect(signedIn.syncDisabledReason(hasKey: false) != nil)
        #expect(signedIn.syncDisabledReason(hasKey: true) == nil)
    }

    @Test("sync ON → toggle stays interactable (can disable) even with an empty key field")
    func toggleEnabledWhenOnEvenWithoutKey() async {
        let mock = MockSecretClient()
        let (svc, kc, acct, settings) = makeService(mock: mock, signedIn: true, enabled: true)
        defer { try? kc.delete(acct) }

        // Sync currently ON, key field empty → the reasons must NOT block OFF.
        #expect(svc.syncDisabledReason(hasKey: false) == nil)

        // Disabling with an empty key field still DELETEs the server copy + clears
        // the flag (opt-out stays reachable — AC6).
        await svc.disable()
        #expect(await mock.deleteCount == 1)
        #expect(!svc.isEnabled)
        #expect(!settings.keySyncEnabled)
    }

    @Test("signed out → uploadIfEnabled makes no network call")
    func signedOutNoNetwork() async {
        let mock = MockSecretClient()
        let (svc, kc, acct, _) = makeService(mock: mock, signedIn: false, enabled: true)
        defer { try? kc.delete(acct) }

        await svc.uploadIfEnabled(key: "sk-x")

        #expect(await mock.uploads.isEmpty)
    }
}

// MARK: - SecretSyncClient (wire mapping + auth reuse)

@Suite("SecretSyncClient — PUT/GET/DELETE mapping + 401→refresh (mirrors SyncClient)")
struct SecretSyncClientTests {

    private let baseURL = URL(string: "https://api.translator.daichenlab.com")!

    @Test("upload PUTs the key with a Bearer header")
    func uploadSendsKeyWithBearer() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        var method: String?
        var authHeader: String?
        var body: Data?
        MockURLProtocol.handler = { request in
            method = request.httpMethod
            authHeader = request.value(forHTTPHeaderField: "Authorization")
            body = MockURLProtocol.lastBody
            return (Data(#"{"updated_at":"2026-06-21T10:00:00Z"}"#.utf8),
                    MockURLProtocol.okResponse(for: request))
        }
        let client = SecretSyncClient(
            auth: FakeSecretAuth(token: "jwt", refreshed: nil),
            session: MockURLProtocol.makeSession(), baseURL: baseURL
        )
        try await client.upload(key: "sk-xyz")

        #expect(method == "PUT")
        #expect(authHeader == "Bearer jwt")
        let json = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
        #expect(json?["key"] as? String == "sk-xyz")
    }

    @Test("fetch maps 200 to .found with the key + updatedAt")
    func fetchMapsFound() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { request in
            (Data(#"{"key":"sk-server","updated_at":"2026-06-21T10:00:00Z"}"#.utf8),
             MockURLProtocol.okResponse(for: request))
        }
        let client = SecretSyncClient(
            auth: FakeSecretAuth(token: "jwt", refreshed: nil),
            session: MockURLProtocol.makeSession(), baseURL: baseURL
        )
        let result = try await client.fetch()
        guard case let .found(key, _) = result else {
            Issue.record("expected .found, got \(result)"); return
        }
        #expect(key == "sk-server")
    }

    @Test("fetch maps 404 to .notFound")
    func fetchMapsNotFound() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let client = SecretSyncClient(
            auth: FakeSecretAuth(token: "jwt", refreshed: nil),
            session: MockURLProtocol.makeSession(), baseURL: baseURL
        )
        #expect(try await client.fetch() == .notFound)
    }

    @Test("signed out → fetch returns .unauthorized, upload throws, no network hit")
    func signedOutNoNetwork() async {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        var hit = false
        MockURLProtocol.handler = { request in
            hit = true
            return (Data(), MockURLProtocol.okResponse(for: request))
        }
        let client = SecretSyncClient(
            auth: FakeSecretAuth(token: nil, refreshed: nil),
            session: MockURLProtocol.makeSession(), baseURL: baseURL
        )
        let result = try? await client.fetch()
        #expect(result == .unauthorized)
        await #expect(throws: SyncError.self) { try await client.upload(key: "sk") }
        #expect(hit == false)
    }

    @Test("401 refreshes once and retries with the fresh token")
    func unauthorizedRefreshesAndRetries() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        nonisolated(unsafe) var tokens: [String] = []
        MockURLProtocol.handler = { request in
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            tokens.append(bearer)
            if bearer == "Bearer stale" {
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(#"{"key":"sk","updated_at":"2026-06-21T10:00:00Z"}"#.utf8),
                    MockURLProtocol.okResponse(for: request))
        }
        let client = SecretSyncClient(
            auth: FakeSecretAuth(token: "stale", refreshed: "fresh"),
            session: MockURLProtocol.makeSession(), baseURL: baseURL
        )
        let result = try await client.fetch()
        guard case .found = result else { Issue.record("expected .found after refresh"); return }
        #expect(tokens.contains("Bearer stale"))
        #expect(tokens.contains("Bearer fresh"))
    }

    @Test("503 (master key unset on server) surfaces as server(503)")
    func masterKeyUnset503() async {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        let client = SecretSyncClient(
            auth: FakeSecretAuth(token: "jwt", refreshed: nil),
            session: MockURLProtocol.makeSession(), baseURL: baseURL
        )
        await #expect(throws: SyncError.server(status: 503)) { try await client.fetch() }
    }
}

// MARK: - Copy (truth-in-UI)

@Suite("KeySyncCopy — verbatim privacy strings (DESIGN §5 / TECH §3.3)")
struct KeySyncCopyTests {

    @Test("sync-OFF string is verbatim")
    func syncOffVerbatim() {
        #expect(KeySyncCopy.engineSyncOff
                == "Stored only in your Mac's Keychain. Never sent anywhere but OpenAI.")
    }

    @Test("sync-ON string is verbatim")
    func syncOnVerbatim() {
        #expect(KeySyncCopy.engineSyncOn
                == "In your Mac's Keychain, and stored on our server (encrypted) so it's "
                + "there when you sign in on another Mac. We keep it encrypted at rest — "
                + "but note we can decrypt it to sync it, so it is not end-to-end encrypted.")
    }

    @Test("Account privacy string is verbatim")
    func accountVerbatim() {
        #expect(KeySyncCopy.accountPrivacy
                == "We store your saved vocabulary as text rows — never your screen images. "
                + "If you turn on key sync, we also store your OpenAI key, encrypted, so "
                + "it follows you across Macs.")
    }

    @Test("sync-ON drops the stale local-only claim and owns the trade")
    func syncOnHasNoStaleClaim() {
        #expect(!KeySyncCopy.engineSyncOn.contains("never written to disk"))
        #expect(KeySyncCopy.engineSyncOn.contains("can decrypt"))
        #expect(KeySyncCopy.engineSyncOn.contains("not end-to-end"))
    }
}

// MARK: - SettingsStore.keySyncEnabled

@Suite("SettingsStore — keySyncEnabled persistence")
struct SettingsStoreKeySyncTests {

    private func makeStore() -> (SettingsStore, UserDefaults) {
        let suite = "SettingsStoreKeySync-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SettingsStore(defaults: defaults), defaults)
    }

    @Test("keySyncEnabled defaults to false")
    func defaultsFalse() {
        let (store, _) = makeStore()
        #expect(store.keySyncEnabled == false)
    }

    @Test("keySyncEnabled round-trips through a fresh store")
    func roundTrips() {
        let (store, defaults) = makeStore()
        store.keySyncEnabled = true
        #expect(SettingsStore(defaults: defaults).keySyncEnabled == true)
    }
}
