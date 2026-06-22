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
    func resolve() -> any TranslationEngine {
        if settings.enginePreference == .openai,
           let key = openAIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return OpenAIEngine(apiKey: key, session: session)
        }
        return GoogleEngine(session: session)
    }
}
