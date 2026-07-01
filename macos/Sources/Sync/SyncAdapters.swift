import Foundation
import Observation

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

// MARK: - OpenAI-key sync (login-only · TECH §3)

/// The Engine-tab status line for key sync (TECH §3.2 state machine).
enum KeySyncState: Equatable, Sendable {
    case off
    case syncing
    case synced(Date)
    case failed(String)
}

/// A restore-time collision: the server has a key but this Mac already holds a
/// *different* local one. We surface this instead of clobbering (DESIGN §3).
struct KeyConflict: Equatable, Sendable {
    let serverKey: String
    let updatedAt: Date
}

/// The copy strings shown next to the key field / on the Account tab. Extracted
/// so QA can assert them verbatim, and so the *stale* pre-sync line can never
/// silently reappear when sync is ON (DESIGN §5 truth-in-UI, TECH §3.3).
enum KeySyncCopy {
    /// Engine tab, sync OFF — the honest local-only promise.
    static let engineSyncOff =
        "Stored only in your Mac's Keychain. Never sent anywhere but OpenAI."
    /// Engine tab, sync ON — explicitly states we can decrypt it (not E2E).
    static let engineSyncOn =
        "In your Mac's Keychain, and stored on our server (encrypted) so it's "
        + "there when you sign in on another Mac. We keep it encrypted at rest — "
        + "but note we can decrypt it to sync it, so it is not end-to-end encrypted."
    /// Account tab privacy line.
    static let accountPrivacy =
        "We store your saved vocabulary as text rows — never your screen images. "
        + "If you turn on key sync, we also store your OpenAI key, encrypted, so "
        + "it follows you across Macs."
    /// The auto-restore confirmation (R5 — Engine status + Account signed-in).
    static let restoredToast = "Restored your OpenAI key"
    /// Disabled-reason when signed out.
    static let disabledReasonSignedOut =
        "Sign in on the Account tab to sync your key across your Macs."
    /// Disabled-reason when no key is present yet.
    static let disabledReasonNoKey =
        "Add your OpenAI key above to sync it across your Macs."
}

/// Drives the Engine-tab "Sync this key across my Macs" toggle and the sign-in
/// auto-restore (TECH §3, DESIGN §3). `@MainActor @Observable` so the toggle,
/// status line, conflict alert, and restored toast all re-render on transition.
///
/// The *only* mutation of the local Keychain happens in `restoreAfterSignIn`
/// (write on empty) and conflict adoption — never on fetch failure / empty
/// server (never-wipe) and never on a differing local key (don't-clobber).
@MainActor
@Observable
final class KeySyncService {

    /// The Engine-tab status line.
    private(set) var state: KeySyncState = .off
    /// Mirrors `settings.keySyncEnabled` as an observable so the toggle tracks it
    /// (including a silent re-arm from `restoreAfterSignIn`).
    private(set) var isEnabled: Bool
    /// Set true after a silent auto-restore; the Engine status + Account
    /// signed-in view show "Restored your OpenAI key" until acknowledged.
    var showRestoredToast = false
    /// Non-nil when a restore hit a *different* local key — drives the one-time
    /// "keep this Mac's key or use the synced one?" alert.
    var pendingConflict: KeyConflict?

    private let client: any SecretSyncClientProtocol
    private let keychain: KeychainStore
    private let settings: SettingsStore
    private let isSignedInProvider: @MainActor () -> Bool

    init(
        client: any SecretSyncClientProtocol,
        keychain: KeychainStore = KeychainStore(),
        settings: SettingsStore = SettingsStore(),
        isSignedIn: @escaping @MainActor () -> Bool = { false }
    ) {
        self.client = client
        self.keychain = keychain
        self.settings = settings
        self.isSignedInProvider = isSignedIn
        self.isEnabled = settings.keySyncEnabled
    }

    /// `true` when there is a signed-in session — required to sync at all.
    var isSignedIn: Bool { isSignedInProvider() }

    /// The one-line reason the toggle is disabled, or `nil` when it can be used.
    /// `hasKey` is passed from the view (the live key field), not the Keychain,
    /// so the reason reacts to typing before the key is even persisted.
    func syncDisabledReason(hasKey: Bool) -> String? {
        if !isSignedIn { return KeySyncCopy.disabledReasonSignedOut }
        if !hasKey { return KeySyncCopy.disabledReasonNoKey }
        return nil
    }

    // MARK: - Toggle

    /// User turned the toggle ON: PUT the key, confirm 2xx before showing Synced
    /// (DESIGN §3). Reverts if there is no key / not signed in (defensive — the
    /// toggle is disabled in those states).
    func enable(key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isSignedIn else {
            setEnabled(false)
            state = .off
            return
        }
        setEnabled(true)
        await upload(trimmed)
    }

    /// User turned the toggle OFF: DELETE the server copy; the local Keychain key
    /// is kept (opt-out removes the cloud copy only — AC6). Best-effort delete.
    func disable() async {
        setEnabled(false)
        state = .off
        pendingConflict = nil
        try? await client.delete()
    }

    /// Re-upload after an in-place key edit while sync is ON (DESIGN §3). A no-op
    /// when off / signed out (→ no network) or when the field was *cleared* —
    /// clearing the field does NOT delete the server copy (R2).
    func uploadIfEnabled(key: String) async {
        guard isEnabled, isSignedIn else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await upload(trimmed)
    }

    // MARK: - Sign-in auto-restore (the never-wipe / don't-clobber branch)

    /// After sign-in, GET the server key and branch (TECH §3.2):
    /// - fetch error / 404 / signed-out → **no-op** (never wipe the local key),
    /// - local empty → **restore** to the Keychain + toast + arm the flag,
    /// - same key → **re-arm** the flag silently,
    /// - different local key → **conflict** (don't clobber; prompt the user).
    func restoreAfterSignIn() async {
        let result: SecretFetchResult
        do {
            result = try await client.fetch()
        } catch {
            // Transport / 5xx (incl. 503 no-master-key) — keep the local key.
            return
        }

        switch result {
        case .notFound, .unauthorized:
            return
        case let .found(serverKey, updatedAt):
            let trimmedServer = serverKey.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty / whitespace-only server key is not a real key — treat it
            // exactly like `.notFound`: never write the Keychain, never raise a
            // conflict, never wipe or arm anything.
            guard !trimmedServer.isEmpty else { return }
            let local = currentLocalKey()
            if local.isEmpty {
                try? keychain.set(serverKey, for: KeychainStore.openAIKeyAccount)
                setEnabled(true)
                state = .synced(updatedAt)
                showRestoredToast = true
            } else if local == trimmedServer {
                setEnabled(true)
                state = .synced(updatedAt)
            } else {
                pendingConflict = KeyConflict(serverKey: serverKey, updatedAt: updatedAt)
            }
        }
    }

    // MARK: - Conflict resolution

    /// Keep this Mac's existing key (the alert default); leave the server copy
    /// untouched and dismiss the prompt.
    func resolveConflictKeepingLocal() {
        pendingConflict = nil
    }

    /// Adopt the synced key: overwrite the local Keychain with the server copy,
    /// arm the flag, and dismiss the prompt.
    func resolveConflictAdoptingSynced() {
        guard let conflict = pendingConflict else { return }
        // Defensive: never overwrite a good local key with an empty/whitespace
        // one. (The restore branch already makes an empty-key conflict
        // impossible, so this is belt-and-suspenders.)
        guard !conflict.serverKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingConflict = nil
            return
        }
        try? keychain.set(conflict.serverKey, for: KeychainStore.openAIKeyAccount)
        setEnabled(true)
        state = .synced(conflict.updatedAt)
        pendingConflict = nil
    }

    /// Dismiss the restored confirmation (the view calls this once shown).
    func acknowledgeRestoredToast() {
        showRestoredToast = false
    }

    // MARK: - Sign-out / account-delete

    /// Sign-out: sync can't run signed-out, so clear the intent flag. The local
    /// Keychain key and the server copy are both kept (a later sign-in re-arms).
    func handleSignOut() {
        setEnabled(false)
        state = .off
        pendingConflict = nil
        showRestoredToast = false
    }

    /// Account delete: the server cascades the secret row away; clear the local
    /// flag/state. The local Keychain key is kept (AC6).
    func handleAccountDeleted() {
        setEnabled(false)
        state = .off
        pendingConflict = nil
        showRestoredToast = false
    }

    // MARK: - Helpers

    private func upload(_ key: String) async {
        state = .syncing
        do {
            try await client.upload(key: key)
            state = .synced(Date())
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    private func currentLocalKey() -> String {
        (keychain.string(for: KeychainStore.openAIKeyAccount) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func setEnabled(_ value: Bool) {
        settings.keySyncEnabled = value
        isEnabled = value
    }

    /// User-facing reason for a failed sync.
    static func message(for error: Error) -> String {
        if case SyncError.server(status: 503) = error {
            return "Sync is temporarily unavailable. Your key stays on this Mac."
        }
        return "Couldn't sync your key. It's still saved on this Mac."
    }
}
