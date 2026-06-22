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
/// Slice 3 needs only `enginePreference`. Default target language,
/// launch-at-login, and the last-sync cursor land with the full Preferences UI
/// in slice 5. Secrets (the OpenAI key) live in `KeychainStore`, never here.
final class SettingsStore {

    private enum Key {
        static let enginePreference = "enginePreference"
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
}
