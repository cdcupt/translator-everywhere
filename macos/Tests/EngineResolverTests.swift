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

    // MARK: - resolve(for:) — a-priori per-target routing (slice 4)

    /// An AI-capable target (every v1 language has `aiName`).
    private var aiCapableTarget: Language {
        LanguageCatalog.language(forCode: "zh-CN")!
    }

    /// A synthetic, AI-incapable target — `aiName == nil`, exercising the branch
    /// that v1's real catalog never hits.
    private var aiIncapableTarget: Language {
        Language(
            code: "xx",
            englishName: "Test",
            endonym: "Test",
            googleCode: "xx",
            aiName: nil,
            aliases: []
        )
    }

    @Test(".openai + key + AI-capable target → OpenAI, not via Google")
    func resolveForOpenAICapable() {
        let resolver = EngineResolver(
            settings: makeSettings(.openai),
            openAIKey: { "sk-real-key" }
        )
        let resolved = resolver.resolve(for: LanguagePair(from: nil, to: aiCapableTarget))
        #expect(resolved.engine.kind == .ai)
        #expect(resolved.viaGoogleFallback == false)
    }

    @Test(".openai + key + AI-incapable target → Google, via Google")
    func resolveForOpenAIIncapable() {
        let resolver = EngineResolver(
            settings: makeSettings(.openai),
            openAIKey: { "sk-real-key" }
        )
        let resolved = resolver.resolve(for: LanguagePair(from: nil, to: aiIncapableTarget))
        #expect(resolved.engine.kind == .free)
        #expect(resolved.viaGoogleFallback == true)
    }

    @Test(".free preference → Google, ordinary FREE (not a fallback)")
    func resolveForFree() {
        let resolver = EngineResolver(
            settings: makeSettings(.free),
            openAIKey: { "sk-present" } // present, but preference is .free
        )
        let resolved = resolver.resolve(for: LanguagePair(from: nil, to: aiCapableTarget))
        #expect(resolved.engine.kind == .free)
        #expect(resolved.viaGoogleFallback == false)
    }

    @Test(".openai + no key → Google, ordinary FREE (not a fallback)")
    func resolveForOpenAINoKey() {
        let resolver = EngineResolver(
            settings: makeSettings(.openai),
            openAIKey: { nil }
        )
        let resolved = resolver.resolve(for: LanguagePair(from: nil, to: aiCapableTarget))
        #expect(resolved.engine.kind == .free)
        #expect(resolved.viaGoogleFallback == false)
    }

    // MARK: - resolveSelection(for:) — selection routing truth table (slice S2)

    @Test("U-28 · .openai + key + AI-capable target → .contextual(OpenAIEngine)") // FR-2
    func selectionRouteContextualWhenAIAvailable() {
        let resolver = EngineResolver(
            settings: makeSettings(.openai),
            openAIKey: { "sk-real-key" }
        )
        let route = resolver.resolveSelection(for: LanguagePair(from: nil, to: aiCapableTarget))
        guard case .contextual(let engine) = route else {
            Issue.record("expected .contextual, got .contextFree")
            return
        }
        #expect(engine is OpenAIEngine)
    }

    @Test("U-29 · no OpenAI key → .contextFree(GoogleEngine)") // AC-4 · FR-5
    func selectionRouteContextFreeWithoutKey() {
        let resolver = EngineResolver(
            settings: makeSettings(.openai),
            openAIKey: { nil }
        )
        let route = resolver.resolveSelection(for: LanguagePair(from: nil, to: aiCapableTarget))
        guard case .contextFree(let engine) = route else {
            Issue.record("expected .contextFree, got .contextual")
            return
        }
        #expect(engine.kind == .free)
    }

    @Test("U-30 · .free preference, key present → .contextFree — same truth table as resolve(for:)") // FR-5
    func selectionRouteContextFreeForFreePreference() {
        let resolver = EngineResolver(
            settings: makeSettings(.free),
            openAIKey: { "sk-present" } // present, but preference is .free
        )
        let route = resolver.resolveSelection(for: LanguagePair(from: nil, to: aiCapableTarget))
        guard case .contextFree(let engine) = route else {
            Issue.record("expected .contextFree, got .contextual")
            return
        }
        #expect(engine.kind == .free)
    }

    @Test("U-31 · target language not aiSupported → .contextFree") // FR-5
    func selectionRouteContextFreeForAIIncapableTarget() {
        let resolver = EngineResolver(
            settings: makeSettings(.openai),
            openAIKey: { "sk-real-key" }
        )
        let route = resolver.resolveSelection(for: LanguagePair(from: nil, to: aiIncapableTarget))
        guard case .contextFree(let engine) = route else {
            Issue.record("expected .contextFree, got .contextual")
            return
        }
        #expect(engine.kind == .free)
    }
}
