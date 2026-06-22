import Foundation
import Testing
@testable import Translator_Everywhere

@Suite("EngineResolver — preference + key fallback")
struct EngineResolverTests {

    /// A `SettingsStore` over an isolated, in-memory `UserDefaults` suite so the
    /// test never touches the real defaults.
    private func makeSettings(_ preference: EnginePreference) -> SettingsStore {
        let suite = "EngineResolverTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults)
        settings.enginePreference = preference
        return settings
    }

    @Test("Default .free preference resolves to Google")
    func freeResolvesToGoogle() {
        let resolver = EngineResolver(
            settings: makeSettings(.free),
            openAIKey: { "sk-present" } // present, but preference is .free
        )
        #expect(resolver.resolve().kind == .free)
    }

    @Test(".openai with no key falls back to Google")
    func openAIWithoutKeyFallsBack() {
        let resolver = EngineResolver(
            settings: makeSettings(.openai),
            openAIKey: { nil }
        )
        #expect(resolver.resolve().kind == .free)
    }

    @Test(".openai with a blank key falls back to Google")
    func openAIWithBlankKeyFallsBack() {
        let resolver = EngineResolver(
            settings: makeSettings(.openai),
            openAIKey: { "   " }
        )
        #expect(resolver.resolve().kind == .free)
    }

    @Test(".openai with a key resolves to OpenAI")
    func openAIWithKeyResolvesToOpenAI() {
        let resolver = EngineResolver(
            settings: makeSettings(.openai),
            openAIKey: { "sk-real-key" }
        )
        #expect(resolver.resolve().kind == .ai)
    }

    @Test("SettingsStore defaults to .free when unset")
    func settingsDefaultsToFree() {
        let suite = "EngineResolverTests-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        #expect(SettingsStore(defaults: defaults).enginePreference == .free)
    }
}
