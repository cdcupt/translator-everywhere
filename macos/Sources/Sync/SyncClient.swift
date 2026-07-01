import Foundation

/// The cursor persistence the SyncClient needs (so it can be faked in tests).
protocol SyncCursorStore: Sendable {
    func loadCursor() -> Date?
    func saveCursor(_ date: Date)
}

/// Supplies the current session JWT and a refresh hook. `AuthClient` provides
/// the real implementation; tests inject a fake to exercise the 401→refresh
/// path. `Sendable` so it can cross into the actor.
protocol SyncAuthProvider: Sendable {
    /// The current access JWT, or `nil` when signed out (→ sync is a no-op).
    func currentAccessToken() async -> String?
    /// Refresh on 401; returns the new JWT, or `nil` if refresh failed (caller
    /// gives up this cycle and stays signed out).
    func refreshAccessToken() async -> String?
}

/// Speaks the §7 backend contract (TECH §8.5).
///
/// An `actor` over `URLSession`: a push-then-pull cycle, last-write-wins by
/// `updatedAt` keyed on `clientUUID`, with a `since=` cursor. Background &
/// best-effort — failures are swallowed and retried next cycle; the notebook
/// keeps working offline. Does NOTHING when signed out.
actor SyncClient {

    /// Why a sync ran — shapes the cursor used and whether a full push happens.
    enum Trigger: Sendable {
        case signIn        // full push of everything + pull since 0
        case localChange   // push dirty + incremental pull
        case foreground    // incremental pull + push dirty
    }

    private let session: URLSession
    private let baseURL: URL
    private let store: any VocabSyncStore
    private let cursors: SyncCursorStore
    private let auth: SyncAuthProvider

    init(
        store: any VocabSyncStore,
        auth: SyncAuthProvider,
        cursors: SyncCursorStore,
        session: URLSession = .shared,
        baseURL: URL = AuthConfig.backendBaseURL
    ) {
        self.store = store
        self.auth = auth
        self.cursors = cursors
        self.session = session
        self.baseURL = baseURL
    }

    /// Runs one push-then-pull cycle. Returns the server clock from the pull (the
    /// new cursor), or `nil` when signed out / on failure. Never throws — sync is
    /// best-effort. On `.signIn` the cursor is reset to `0` for a full pull.
    @discardableResult
    func sync(trigger: Trigger = .localChange) async -> Date? {
        guard let token = await auth.currentAccessToken() else { return nil }
        do {
            return try await runCycle(trigger: trigger, token: token, didRefresh: false)
        } catch {
            return nil
        }
    }

    // MARK: - Cycle

    private func runCycle(trigger: Trigger, token: String, didRefresh: Bool) async throws -> Date? {
        do {
            try await push(token: token)
            let serverTime = try await pull(trigger: trigger, token: token)
            if let serverTime { cursors.saveCursor(serverTime) }
            return serverTime
        } catch SyncError.unauthorized where !didRefresh {
            // 401 → refresh once, then retry the whole cycle.
            guard let fresh = await auth.refreshAccessToken() else { throw SyncError.unauthorized }
            return try await runCycle(trigger: trigger, token: fresh, didRefresh: true)
        }
    }

    // MARK: - Push

    private func push(token: String) async throws {
        let dirty = try await store.dirtyRows()
        guard !dirty.isEmpty else { return }

        let body = VocabPushRequest(items: dirty.map(VocabItemDTO.init(row:)))
        var request = URLRequest(url: baseURL.appendingPathComponent("vocab"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)

        let (data, response) = try await data(for: request)
        try Self.ensureOK(response)

        // Adopt any server-newer conflict rows the merge returned, then clear
        // dirty — but only for rows whose live `updatedAt` still matches what we
        // pushed. Carry the snapshot `updatedAt` per clientUUID so an edit made
        // DURING this in-flight push (which bumps `updatedAt` and re-dirties the
        // row) is NOT wiped from the queue → no lost update.
        if let decoded = try? Self.decoder.decode(VocabPushResponse.self, from: data) {
            for dto in decoded.conflicts {
                if let row = dto.toRow() { _ = try await store.mergePulled(row) }
            }
        }
        let pushed = Dictionary(dirty.map { ($0.clientUUID, $0.updatedAt) }, uniquingKeysWith: { _, last in last })
        try await store.clearDirty(pushed)
    }

    // MARK: - Pull

    private func pull(trigger: Trigger, token: String) async throws -> Date? {
        let since: Date? = (trigger == .signIn) ? nil : cursors.loadCursor()
        var components = URLComponents(
            url: baseURL.appendingPathComponent("vocab"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "since", value: Self.iso8601.string(from: since ?? Date(timeIntervalSince1970: 0)))
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await data(for: request)
        try Self.ensureOK(response)

        let decoded = try Self.decoder.decode(VocabPullResponse.self, from: data)
        for dto in decoded.items {
            if let row = dto.toRow() { _ = try await store.mergePulled(row) }
        }
        return decoded.serverTime
    }

    // MARK: - Transport

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw SyncError.transport
        }
    }

    private static func ensureOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw SyncError.transport }
        if http.statusCode == 401 { throw SyncError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw SyncError.server(status: http.statusCode)
        }
    }

    // Shared JSON coders. `server_time` / `updated_at` are RFC3339 strings.
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601.string(from: date))
        }
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Tolerate fractional seconds the server may or may not include.
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = iso8601
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = withFrac.date(from: raw) ?? plain.date(from: raw) { return date }
            throw SyncError.decoding
        }
        return d
    }()
}

/// SyncClient internal errors (never surfaced to the user — best-effort sync).
enum SyncError: Error, Equatable {
    case unauthorized
    case server(status: Int)
    case transport
    case decoding
}

// MARK: - Wire DTOs (match server/internal/api/vocab_handlers.go exactly)

struct VocabItemDTO: Codable, Sendable {
    let clientUUID: String
    let sourceText: String
    let translation: String
    let srcLang: String
    let tgtLang: String
    let engine: String
    let tag: String?
    let deleted: Bool
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case clientUUID = "client_uuid"
        case sourceText = "source_text"
        case translation
        case srcLang = "src_lang"
        case tgtLang = "tgt_lang"
        case engine
        case tag
        case deleted
        case updatedAt = "updated_at"
    }

    init(row: VocabRow) {
        self.clientUUID = row.clientUUID.uuidString.lowercased()
        self.sourceText = row.sourceText
        self.translation = row.translation
        self.srcLang = row.srcLang
        self.tgtLang = row.tgtLang
        // The local model stores EngineKind.rawValue ("free" | "ai"), but the
        // server's enum is "free" | "openai" (§7). Map on the wire so a pushed
        // AI row isn't rejected.
        self.engine = Self.serverEngine(row.engine)
        self.tag = row.tag
        self.deleted = row.tombstoned
        self.updatedAt = row.updatedAt
    }

    /// Local engine token → server enum.
    static func serverEngine(_ local: String) -> String {
        local == "ai" ? "openai" : local
    }

    /// Server enum → local `EngineKind.rawValue`.
    static func localEngine(_ server: String) -> String {
        server == "openai" ? "ai" : server
    }

    /// Back to a value row; `nil` if the `client_uuid` isn't a valid UUID.
    func toRow() -> VocabRow? {
        guard let uuid = UUID(uuidString: clientUUID) else { return nil }
        return VocabRow(
            clientUUID: uuid,
            sourceText: sourceText,
            translation: translation,
            srcLang: srcLang,
            tgtLang: tgtLang,
            engine: Self.localEngine(engine),
            tag: tag,
            // The server is the source of truth for createdAt only at insert;
            // merge keys off updatedAt, so reuse it as a stable createdAt proxy
            // for a row that lands here before we've ever seen it locally.
            createdAt: updatedAt,
            updatedAt: updatedAt,
            tombstoned: deleted
        )
    }
}

struct VocabPushRequest: Encodable {
    let items: [VocabItemDTO]
}

struct VocabPushResponse: Decodable {
    let applied: Int
    let conflicts: [VocabItemDTO]
    let serverTime: Date
    enum CodingKeys: String, CodingKey {
        case applied, conflicts
        case serverTime = "server_time"
    }
}

struct VocabPullResponse: Decodable {
    let items: [VocabItemDTO]
    let serverTime: Date
    enum CodingKeys: String, CodingKey {
        case items
        case serverTime = "server_time"
    }
}

// MARK: - Secret sync (OpenAI-key sync, login-only · TECH §3–§4)

/// Outcome of a `GET /secret/openai-key` (TECH §4 wire contract).
///
/// `.found` carries the decrypted key + its server `updated_at`; `.notFound`
/// is a clean 404 (no row); `.unauthorized` means the session couldn't be
/// refreshed (signed out) — the caller must treat all three as *never wipe the
/// local key*.
enum SecretFetchResult: Sendable, Equatable {
    case found(key: String, updatedAt: Date)
    case notFound
    case unauthorized
}

/// The seam both the app and the tests implement — a tiny PUT/GET/DELETE client
/// for the single `openai-key` secret. `Sendable` so it can cross into
/// `KeySyncService`'s `@MainActor` and be swapped for a mock in tests.
protocol SecretSyncClientProtocol: Sendable {
    /// PUT the key (encrypt-at-rest server side). Throws on transport / non-2xx
    /// (incl. `SyncError.server(status: 503)` when the master key is unset).
    func upload(key: String) async throws
    /// GET the key. Never throws for 404 / signed-out — those map to
    /// `.notFound` / `.unauthorized`; only transport / 5xx throw.
    func fetch() async throws -> SecretFetchResult
    /// DELETE the server copy (idempotent). Throws on transport / non-2xx.
    func delete() async throws
}

/// Talks the `/secret/openai-key` contract, mirroring `SyncClient`: an `actor`
/// over `URLSession`, reusing the same `SyncAuthProvider` seam and the exact
/// **401 → refresh once → retry** pattern (see `SyncClient.runCycle`). No client
/// crypto — the key is sent/received as-is over TLS; the server owns encryption
/// at rest (DESIGN §2).
actor SecretSyncClient: SecretSyncClientProtocol {

    private let session: URLSession
    private let baseURL: URL
    private let auth: SyncAuthProvider

    /// The single secret slot — the handler hardcodes `"openai-key"`; the client
    /// never sends a caller-supplied name (TECH §2.1).
    private static let path = "secret/openai-key"

    init(
        auth: SyncAuthProvider,
        session: URLSession = .shared,
        baseURL: URL = AuthConfig.backendBaseURL
    ) {
        self.auth = auth
        self.session = session
        self.baseURL = baseURL
    }

    // MARK: PUT

    func upload(key: String) async throws {
        guard let token = await auth.currentAccessToken() else { throw SyncError.unauthorized }
        try await sendUpload(key: key, token: token, didRefresh: false)
    }

    private func sendUpload(key: String, token: String, didRefresh: Bool) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(Self.path))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(SecretPutRequest(key: key))

        let (_, response) = try await data(for: request)
        do {
            try Self.ensureOK(response)
        } catch SyncError.unauthorized where !didRefresh {
            guard let fresh = await auth.refreshAccessToken() else { throw SyncError.unauthorized }
            try await sendUpload(key: key, token: fresh, didRefresh: true)
        }
    }

    // MARK: GET

    func fetch() async throws -> SecretFetchResult {
        guard let token = await auth.currentAccessToken() else { return .unauthorized }
        return try await sendFetch(token: token, didRefresh: false)
    }

    private func sendFetch(token: String, didRefresh: Bool) async throws -> SecretFetchResult {
        var request = URLRequest(url: baseURL.appendingPathComponent(Self.path))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.transport }
        switch http.statusCode {
        case 200:
            let decoded = try decode(SecretGetResponse.self, from: data)
            return .found(key: decoded.key, updatedAt: decoded.updatedAt)
        case 404:
            return .notFound
        case 401:
            // 401 → refresh once → retry; a still-failing refresh means signed
            // out → `.unauthorized` (the caller must NOT wipe the local key).
            guard !didRefresh, let fresh = await auth.refreshAccessToken() else { return .unauthorized }
            return try await sendFetch(token: fresh, didRefresh: true)
        default:
            throw SyncError.server(status: http.statusCode)
        }
    }

    // MARK: DELETE

    func delete() async throws {
        guard let token = await auth.currentAccessToken() else { throw SyncError.unauthorized }
        try await sendDelete(token: token, didRefresh: false)
    }

    private func sendDelete(token: String, didRefresh: Bool) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(Self.path))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.transport }
        switch http.statusCode {
        case 200, 204:
            return
        case 401:
            guard !didRefresh, let fresh = await auth.refreshAccessToken() else { throw SyncError.unauthorized }
            try await sendDelete(token: fresh, didRefresh: true)
        default:
            throw SyncError.server(status: http.statusCode)
        }
    }

    // MARK: Transport / coding (self-contained; mirrors SyncClient)

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw SyncError.transport
        }
    }

    private static func ensureOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw SyncError.transport }
        if http.statusCode == 401 { throw SyncError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw SyncError.server(status: http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try Self.decoder.decode(type, from: data) }
        catch { throw SyncError.decoding }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let encoder = JSONEncoder()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = iso8601
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = withFrac.date(from: raw) ?? plain.date(from: raw) { return date }
            throw SyncError.decoding
        }
        return d
    }()
}

/// `PUT /secret/openai-key` body (TECH §4).
private struct SecretPutRequest: Encodable {
    let key: String
}

/// `GET /secret/openai-key` 200 body (TECH §4).
private struct SecretGetResponse: Decodable {
    let key: String
    let updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case key
        case updatedAt = "updated_at"
    }
}
