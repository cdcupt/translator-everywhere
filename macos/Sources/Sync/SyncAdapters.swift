import Foundation

/// Bridges `AuthClient` to the SyncClient's `SyncAuthProvider`. Lives outside
/// `AuthClient` so the auth module stays free of sync concerns.
///
/// `AuthClient` is a reference type touching the Keychain; reads here are
/// `nonisolated`-safe (Keychain access is thread-safe), so we mark the adapter
/// `@unchecked Sendable`.
final class AuthClientSyncProvider: SyncAuthProvider, @unchecked Sendable {

    private let auth: AuthClient

    init(_ auth: AuthClient) { self.auth = auth }

    func currentAccessToken() async -> String? {
        auth.currentSession?.sessionJWT
    }

    func refreshAccessToken() async -> String? {
        try? await auth.refreshSession()
    }
}

/// A `UserDefaults`-backed sync cursor (the `server_time` from the last pull).
/// Standalone & `Sendable` so it can cross into the SyncClient actor without
/// dragging the non-Sendable `SettingsStore` along.
struct DefaultsCursorStore: SyncCursorStore {

    private static let key = "sync.lastSyncedAt"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadCursor() -> Date? {
        let raw = defaults.double(forKey: Self.key)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    func saveCursor(_ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.key)
    }
}
