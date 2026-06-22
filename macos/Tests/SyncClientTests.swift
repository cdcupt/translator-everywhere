import Foundation
import Testing
@testable import Translator_Everywhere

/// An in-memory `VocabSyncStore` fake — no SwiftData. Records dirty-clears and
/// applies last-write-wins exactly like `NotebookStore+Sync`.
@MainActor
private final class FakeStore: VocabSyncStore {
    var rows: [UUID: VocabRow] = [:]
    var dirty: Set<UUID> = []
    var clearedDirty: [[UUID]] = []

    func seed(_ row: VocabRow, dirty isDirty: Bool) {
        rows[row.clientUUID] = row
        if isDirty { dirty.insert(row.clientUUID) }
    }

    func dirtyRows() throws -> [VocabRow] {
        dirty.compactMap { rows[$0] }
    }

    func clearDirty(_ clientUUIDs: [UUID]) throws {
        clearedDirty.append(clientUUIDs)
        for id in clientUUIDs { dirty.remove(id) }
    }

    @discardableResult
    func mergePulled(_ row: VocabRow) throws -> Bool {
        guard let existing = rows[row.clientUUID] else {
            rows[row.clientUUID] = row
            return true
        }
        guard row.updatedAt > existing.updatedAt else { return false }
        rows[row.clientUUID] = row
        return true
    }
}

/// A configurable auth provider for the no-op + 401-refresh paths.
private struct FakeAuth: SyncAuthProvider {
    let token: String?
    let refreshed: String?
    func currentAccessToken() async -> String? { token }
    func refreshAccessToken() async -> String? { refreshed }
}

/// An in-memory cursor.
private final class FakeCursor: SyncCursorStore, @unchecked Sendable {
    var date: Date?
    func loadCursor() -> Date? { date }
    func saveCursor(_ date: Date) { self.date = date }
}

@Suite("SyncClient — push, pull merge, tombstone, 401 refresh, no-op")
struct SyncClientTests {

    private let baseURL = URL(string: "https://api.translator.daichenlab.com")!
    private let iso = ISO8601DateFormatter()

    private func row(
        _ uuid: UUID = UUID(),
        text: String = "hello",
        translation: String = "你好",
        updatedAt: Date,
        tombstoned: Bool = false
    ) -> VocabRow {
        VocabRow(
            clientUUID: uuid, sourceText: text, translation: translation,
            srcLang: "auto", tgtLang: "zh-CN", engine: "free", tag: nil,
            createdAt: updatedAt, updatedAt: updatedAt, tombstoned: tombstoned
        )
    }

    private func pullBody(items: String = "[]", serverTime: String) -> Data {
        Data(#"{"items":\#(items),"server_time":"\#(serverTime)"}"#.utf8)
    }

    // MARK: - Signed-out no-op

    @Test("signed out → sync is a no-op (no network, no dirty clear)")
    func signedOutNoOp() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        var hit = false
        MockURLProtocol.handler = { request in
            hit = true
            return (Data(), MockURLProtocol.okResponse(for: request))
        }
        let store = await FakeStore()
        await MainActor.run { store.seed(self.row(updatedAt: Date()), dirty: true) }
        let client = SyncClient(
            store: store, auth: FakeAuth(token: nil, refreshed: nil),
            cursors: FakeCursor(), session: MockURLProtocol.makeSession(), baseURL: baseURL
        )
        let result = await client.sync()
        #expect(result == nil)
        #expect(hit == false)
    }

    // MARK: - Push

    @Test("push sends dirty rows in §7 body shape and clears isDirty")
    func pushSendsDirtyAndClears() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let id = UUID()
        let store = await FakeStore()
        await MainActor.run {
            store.seed(self.row(id, updatedAt: Date(timeIntervalSince1970: 1_700_000_000)), dirty: true)
        }

        var pushBody: Data?
        MockURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                pushBody = MockURLProtocol.lastBody
                return (Data(#"{"applied":1,"conflicts":[],"server_time":"2026-06-21T10:00:00Z"}"#.utf8),
                        MockURLProtocol.okResponse(for: request))
            }
            return (self.pullBody(serverTime: "2026-06-21T10:00:00Z"), MockURLProtocol.okResponse(for: request))
        }

        let cursor = FakeCursor()
        let client = SyncClient(
            store: store, auth: FakeAuth(token: "jwt", refreshed: nil),
            cursors: cursor, session: MockURLProtocol.makeSession(), baseURL: baseURL
        )
        _ = await client.sync(trigger: .localChange)

        // Body shape: items array with snake_case keys.
        let json = try JSONSerialization.jsonObject(with: pushBody ?? Data()) as? [String: Any]
        let items = json?["items"] as? [[String: Any]]
        #expect(items?.count == 1)
        #expect(items?.first?["client_uuid"] as? String == id.uuidString.lowercased())
        #expect(items?.first?["source_text"] as? String == "hello")
        #expect(items?.first?["deleted"] as? Bool == false)

        let cleared = await MainActor.run { store.clearedDirty }
        #expect(cleared.flatMap { $0 }.contains(id))
        let stillDirty = await MainActor.run { store.dirty }
        #expect(stillDirty.isEmpty)
    }

    @Test("local 'ai' engine is mapped to server 'openai' on push (and back on pull)")
    func engineMappingOnWire() {
        #expect(VocabItemDTO.serverEngine("ai") == "openai")
        #expect(VocabItemDTO.serverEngine("free") == "free")
        #expect(VocabItemDTO.localEngine("openai") == "ai")
        #expect(VocabItemDTO.localEngine("free") == "free")
    }

    @Test("push Bearer header carries the access token")
    func pushBearerHeader() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let store = await FakeStore()
        await MainActor.run { store.seed(self.row(updatedAt: Date()), dirty: true) }
        var authHeader: String?
        MockURLProtocol.handler = { request in
            if request.httpMethod == "POST" { authHeader = request.value(forHTTPHeaderField: "Authorization") }
            return (self.pullBody(serverTime: "2026-06-21T10:00:00Z"), MockURLProtocol.okResponse(for: request))
        }
        let client = SyncClient(
            store: store, auth: FakeAuth(token: "my.jwt", refreshed: nil),
            cursors: FakeCursor(), session: MockURLProtocol.makeSession(), baseURL: baseURL
        )
        _ = await client.sync()
        #expect(authHeader == "Bearer my.jwt")
    }

    // MARK: - Pull merge

    @Test("pull merges a newer remote row by last-write-wins on updatedAt")
    func pullNewerWins() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let id = UUID()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_001_000)
        let store = await FakeStore()
        await MainActor.run { store.seed(self.row(id, translation: "stale", updatedAt: old), dirty: false) }

        let remoteUpdated = iso.string(from: newer)
        let item = #"{"client_uuid":"\#(id.uuidString.lowercased())","source_text":"hello","translation":"fresh","src_lang":"auto","tgt_lang":"zh-CN","engine":"free","deleted":false,"updated_at":"\#(remoteUpdated)"}"#
        MockURLProtocol.handler = { request in
            (self.pullBody(items: "[\(item)]", serverTime: "2026-06-21T11:00:00Z"),
             MockURLProtocol.okResponse(for: request))
        }
        let client = SyncClient(
            store: store, auth: FakeAuth(token: "jwt", refreshed: nil),
            cursors: FakeCursor(), session: MockURLProtocol.makeSession(), baseURL: baseURL
        )
        _ = await client.sync(trigger: .signIn)

        let merged = await MainActor.run { store.rows[id] }
        #expect(merged?.translation == "fresh")
        #expect(merged?.updatedAt == newer)
    }

    @Test("pull keeps the local row when it is newer than the remote (LWW)")
    func pullOlderLoses() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let id = UUID()
        let localNew = Date(timeIntervalSince1970: 1_700_005_000)
        let remoteOld = Date(timeIntervalSince1970: 1_700_000_000)
        let store = await FakeStore()
        await MainActor.run { store.seed(self.row(id, translation: "local-new", updatedAt: localNew), dirty: false) }

        let item = #"{"client_uuid":"\#(id.uuidString.lowercased())","source_text":"hello","translation":"remote-old","src_lang":"auto","tgt_lang":"zh-CN","engine":"free","deleted":false,"updated_at":"\#(iso.string(from: remoteOld))"}"#
        MockURLProtocol.handler = { request in
            (self.pullBody(items: "[\(item)]", serverTime: "2026-06-21T11:00:00Z"),
             MockURLProtocol.okResponse(for: request))
        }
        let client = SyncClient(
            store: store, auth: FakeAuth(token: "jwt", refreshed: nil),
            cursors: FakeCursor(), session: MockURLProtocol.makeSession(), baseURL: baseURL
        )
        _ = await client.sync(trigger: .foreground)

        let merged = await MainActor.run { store.rows[id] }
        #expect(merged?.translation == "local-new")
    }

    @Test("pulled tombstone soft-deletes the local row")
    func pullTombstone() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let id = UUID()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let del = Date(timeIntervalSince1970: 1_700_009_000)
        let store = await FakeStore()
        await MainActor.run { store.seed(self.row(id, updatedAt: old, tombstoned: false), dirty: false) }

        let item = #"{"client_uuid":"\#(id.uuidString.lowercased())","source_text":"hello","translation":"你好","src_lang":"auto","tgt_lang":"zh-CN","engine":"free","deleted":true,"updated_at":"\#(iso.string(from: del))"}"#
        MockURLProtocol.handler = { request in
            (self.pullBody(items: "[\(item)]", serverTime: "2026-06-21T12:00:00Z"),
             MockURLProtocol.okResponse(for: request))
        }
        let client = SyncClient(
            store: store, auth: FakeAuth(token: "jwt", refreshed: nil),
            cursors: FakeCursor(), session: MockURLProtocol.makeSession(), baseURL: baseURL
        )
        _ = await client.sync(trigger: .foreground)

        let merged = await MainActor.run { store.rows[id] }
        #expect(merged?.tombstoned == true)
    }

    @Test("pull advances the cursor to server_time")
    func pullAdvancesCursor() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let store = await FakeStore()
        MockURLProtocol.handler = { request in
            (self.pullBody(serverTime: "2026-06-21T13:30:00Z"), MockURLProtocol.okResponse(for: request))
        }
        let cursor = FakeCursor()
        let client = SyncClient(
            store: store, auth: FakeAuth(token: "jwt", refreshed: nil),
            cursors: cursor, session: MockURLProtocol.makeSession(), baseURL: baseURL
        )
        let result = await client.sync(trigger: .foreground)
        #expect(result != nil)
        #expect(cursor.date == result)
    }

    // MARK: - 401 → refresh → retry

    @Test("401 triggers a refresh and a single retry that succeeds")
    func unauthorizedRefreshesAndRetries() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let store = await FakeStore()
        await MainActor.run { store.seed(self.row(updatedAt: Date()), dirty: false) }

        // First GET with the stale token → 401; after refresh, second GET → 200.
        nonisolated(unsafe) var sawTokens: [String] = []
        MockURLProtocol.handler = { request in
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            sawTokens.append(bearer)
            if bearer == "Bearer stale" {
                return (Data("expired".utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
            return (self.pullBody(serverTime: "2026-06-21T14:00:00Z"), MockURLProtocol.okResponse(for: request))
        }
        let client = SyncClient(
            store: store, auth: FakeAuth(token: "stale", refreshed: "fresh"),
            cursors: FakeCursor(), session: MockURLProtocol.makeSession(), baseURL: baseURL
        )
        let result = await client.sync(trigger: .foreground)
        #expect(result != nil)
        #expect(sawTokens.contains("Bearer stale"))
        #expect(sawTokens.contains("Bearer fresh"))
    }

    @Test("401 with a failed refresh gives up (nil) without crashing")
    func unauthorizedRefreshFails() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let store = await FakeStore()
        MockURLProtocol.handler = { request in
            (Data("expired".utf8),
             HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        let client = SyncClient(
            store: store, auth: FakeAuth(token: "stale", refreshed: nil),
            cursors: FakeCursor(), session: MockURLProtocol.makeSession(), baseURL: baseURL
        )
        let result = await client.sync(trigger: .foreground)
        #expect(result == nil)
    }
}
