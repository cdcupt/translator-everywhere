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
/// Holds `enginePreference`, the `didOnboard` first-run flag, and the
/// language-pair selections (home target, secondary, last-used pair, recent
/// targets). Launch-at-login is *not* mirrored here — `SMAppService` is the
/// single source of truth for that (see `LaunchAtLogin`). Secrets (the OpenAI
/// key) live in `KeychainStore`, never here.
final class SettingsStore {

    private enum Key {
        static let enginePreference = "enginePreference"
        static let didOnboard = "didOnboard"
        static let lastSyncedAt = "sync.lastSyncedAt"
        static let lastFromCode = "lastFromCode"
        static let lastToCode = "lastToCode"
        static let homeTargetCode = "homeTargetCode"
        static let secondaryCode = "secondaryCode"
        static let recentTargetCodes = "recentTargetCodes"
    }

    /// First-read defaults — chosen so an upgraded install reproduces today's
    /// behavior exactly (Auto → 中文, secondary English) with zero migration.
    private enum Default {
        /// Sentinel persisted for `from == nil` (Auto-detect) in `lastFromCode`.
        static let autoSentinel = "auto"
        static let homeTargetCode = "zh-CN"
        static let secondaryCode = "en"
        static let recentTargetCap = 5
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

    // MARK: - Language pair (slice 5)

    /// The home target language — the preferred default To. Defaults to
    /// Simplified Chinese (`zh-CN`) when unset, and falls back to it if a stored
    /// code no longer resolves (catalog change / removal).
    var homeTarget: Language {
        get { language(for: Key.homeTargetCode, defaultCode: Default.homeTargetCode) }
        set { defaults.set(newValue.code, forKey: Key.homeTargetCode) }
    }

    /// The secondary language — the one-tap alternate target. Defaults to
    /// English (`en`) when unset, and falls back to it for an unknown code.
    var secondaryLanguage: Language {
        get { language(for: Key.secondaryCode, defaultCode: Default.secondaryCode) }
        set { defaults.set(newValue.code, forKey: Key.secondaryCode) }
    }

    /// The last-used From/To pair. `from` is optional: the `"auto"` sentinel is
    /// persisted for `nil` (Auto-detect), any other value as the `Language`
    /// code. First-read default reproduces today exactly — `from: nil` (Auto),
    /// `to: 中文` (`zh-CN`) — so there is no migration step (S5 parity). A stored
    /// `from` code that no longer resolves reads back as `nil` (Auto); a `to`
    /// that no longer resolves falls back to the home-target default.
    var lastUsedPair: LanguagePair {
        get {
            let from: Language?
            if let raw = defaults.string(forKey: Key.lastFromCode),
               raw != Default.autoSentinel {
                // Known code → that Language; unknown/removed → nil (Auto), safe.
                from = LanguageCatalog.language(forCode: raw)
            } else {
                // Unset or the explicit "auto" sentinel → Auto-detect.
                from = nil
            }
            let to = language(for: Key.lastToCode, defaultCode: Default.homeTargetCode)
            return LanguagePair(from: from, to: to)
        }
        set {
            defaults.set(newValue.from?.code ?? Default.autoSentinel, forKey: Key.lastFromCode)
            defaults.set(newValue.to.code, forKey: Key.lastToCode)
        }
    }

    /// The most-recently-used target languages, most-recent-first, de-duped by
    /// code and capped at five. Unknown/removed codes are dropped on read.
    var recentTargets: [Language] {
        (defaults.stringArray(forKey: Key.recentTargetCodes) ?? [])
            .compactMap { LanguageCatalog.language(forCode: $0) }
    }

    /// Records `language` as the most-recent target: moves it to the front,
    /// de-dupes by code, and trims to the five-item cap.
    func recordRecentTarget(_ language: Language) {
        var codes = defaults.stringArray(forKey: Key.recentTargetCodes) ?? []
        codes.removeAll { $0 == language.code }
        codes.insert(language.code, at: 0)
        if codes.count > Default.recentTargetCap {
            codes = Array(codes.prefix(Default.recentTargetCap))
        }
        defaults.set(codes, forKey: Key.recentTargetCodes)
    }

    // MARK: - Helpers

    /// Resolves the `Language` stored at `key`, falling back to `defaultCode`
    /// when the key is unset or holds a code the catalog no longer knows. The
    /// fallback code is a canonical catalog member (`zh-CN` / `en`), so the
    /// force-unwrap cannot fail.
    private func language(for key: String, defaultCode: String) -> Language {
        if let code = defaults.string(forKey: key),
           let language = LanguageCatalog.language(forCode: code) {
            return language
        }
        return LanguageCatalog.language(forCode: defaultCode)!
    }
}
