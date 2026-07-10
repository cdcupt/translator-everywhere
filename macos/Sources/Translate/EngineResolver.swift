import Foundation

/// Resolves the concrete engine to use for a translation, at call time
/// (TECH §8.4).
///
/// Rule: use OpenAI only when the preference is `.openai` AND a key exists in the
/// Keychain; otherwise fall back to the free Google engine. Resolving lazily
/// (not at app launch) means a key added in Preferences takes effect on the next
/// capture without a relaunch.
struct EngineResolver {

    private let settings: SettingsStore
    private let openAIKey: () -> String?
    private let session: URLSession

    /// Production initializer — reads the OpenAI key from the Keychain.
    init(
        settings: SettingsStore = SettingsStore(),
        keychain: KeychainStore = KeychainStore(),
        session: URLSession = .shared
    ) {
        self.init(
            settings: settings,
            session: session,
            openAIKey: { keychain.string(for: KeychainStore.openAIKeyAccount) }
        )
    }

    /// Testable initializer — injects the key provider directly so unit tests
    /// don't touch the real Keychain.
    init(
        settings: SettingsStore,
        session: URLSession = .shared,
        openAIKey: @escaping () -> String?
    ) {
        self.settings = settings
        self.session = session
        self.openAIKey = openAIKey
    }

    /// The engine for the current preference + key state.
    ///
    /// Pair-agnostic: still used by `summarize` (which is always AI-or-Google by
    /// preference, never per-target-capability). For per-target translation use
    /// `resolve(for:)`.
    func resolve() -> any TranslationEngine {
        if settings.enginePreference == .openai,
           let key = openAIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return OpenAIEngine(apiKey: key, session: session)
        }
        return GoogleEngine(session: session)
    }

    /// The a-priori routing decision for a concrete `pair` (TECH §4).
    ///
    /// Three branches:
    /// - AI preferred, key present, target is AI-capable (`to.aiName != nil`) →
    ///   `OpenAIEngine`, `viaGoogleFallback == false`.
    /// - AI preferred, key present, target *not* AI-capable (`to.aiName == nil`)
    ///   → `GoogleEngine`, `viaGoogleFallback == true`. The AI engine was
    ///   available but can't serve this target, so the request is routed to
    ///   Google; this drives the "via Google" badge.
    /// - Otherwise (no key, or preference is `.free`) → `GoogleEngine`,
    ///   `viaGoogleFallback == false` — an ordinary FREE result, not a fallback.
    ///
    /// This is the *a-priori* decision only. The runtime AI-error → Google safety
    /// net (catch an OpenAI translate failure, retry on Google, set
    /// `viaGoogleFallback`) is **deferred to `TranslationService`** (slice 6),
    /// where the translate call is orchestrated.
    func resolve(for pair: LanguagePair) -> ResolvedEngine {
        if settings.enginePreference == .openai,
           let key = openAIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            if pair.to.aiName != nil {
                return ResolvedEngine(
                    engine: OpenAIEngine(apiKey: key, session: session),
                    viaGoogleFallback: false
                )
            }
            return ResolvedEngine(
                engine: GoogleEngine(session: session),
                viaGoogleFallback: true
            )
        }
        return ResolvedEngine(
            engine: GoogleEngine(session: session),
            viaGoogleFallback: false
        )
    }

    /// The engine route for a contextual-selection lookup (TECH §03·1).
    ///
    /// Same truth table as `resolve(for:)`: AI preferred + key present + target
    /// AI-capable → `.contextual(OpenAIEngine)` (span + context prompt);
    /// otherwise → `.contextFree(GoogleEngine)` (span-only, degraded — drives
    /// the "Context-free" chip, FR-5).
    func resolveSelection(for pair: LanguagePair) -> SelectionRoute {
        if settings.enginePreference == .openai,
           let key = openAIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty,
           pair.to.aiSupported {
            return .contextual(OpenAIEngine(apiKey: key, session: session))
        }
        return .contextFree(GoogleEngine(session: session))
    }
}
