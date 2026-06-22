import Foundation

/// Which translation engine the user prefers (TECH §8.4).
///
/// `.free` is the default and is always available. `.openai` is honored only
/// when an API key is present in the Keychain — the resolver falls back to
/// `.free` otherwise.
enum EnginePreference: String, CaseIterable, Sendable {
    case free
    case openai
}

/// Non-secret preferences backed by `UserDefaults` (TECH §8.1).
///
/// Holds `enginePreference` (slice 3) and the `didOnboard` first-run flag
/// (slice 5). Launch-at-login is *not* mirrored here — `SMAppService` is the
/// single source of truth for that (see `LaunchAtLogin`). Secrets (the OpenAI
/// key) live in `KeychainStore`, never here.
final class SettingsStore {

    private enum Key {
        static let enginePreference = "enginePreference"
        static let didOnboard = "didOnboard"
        static let lastSyncedAt = "sync.lastSyncedAt"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The user's preferred engine; defaults to `.free` when unset or invalid.
    var enginePreference: EnginePreference {
        get {
            guard let raw = defaults.string(forKey: Key.enginePreference),
                  let value = EnginePreference(rawValue: raw)
            else {
                return .free
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.enginePreference)
        }
    }

    /// `true` once the user has finished (or skipped past) first-run onboarding.
    /// Defaults to `false`, so onboarding shows on the very first launch.
    var didOnboard: Bool {
        get { defaults.bool(forKey: Key.didOnboard) }
        set { defaults.set(newValue, forKey: Key.didOnboard) }
    }

    /// The sync cursor — the server clock (`server_time`) from the last
    /// successful pull, sent as `?since=` next time so sync is incremental
    /// (TECH §8.5). `nil` until the first sync; a sign-in resets it to `nil` so
    /// the first pull is a full `since=0`.
    var lastSyncedAt: Date? {
        get {
            let raw = defaults.double(forKey: Key.lastSyncedAt)
            return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Key.lastSyncedAt)
            } else {
                defaults.removeObject(forKey: Key.lastSyncedAt)
            }
        }
    }
}
