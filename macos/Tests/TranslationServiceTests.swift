import Foundation
import Testing
@testable import Translator_Everywhere

/// The orchestration slice 6 owns: detect → guard → resolve(for:) → translate →
/// AI-fallback. Detection is injected (a fixed `DetectedSource`); the resolved
/// engine is driven over `MockURLProtocol`, so the EN⇄ZH guard regression and the
/// AI→Google safety net are deterministic without the network.
@Suite("TranslationService — detect → guard → resolve → translate → fallback", .serialized)
struct TranslationServiceTests {

    private let chinese = LanguageCatalog.language(forCode: "zh-CN")!
    private let english = LanguageCatalog.language(forCode: "en")!
    private let japanese = LanguageCatalog.language(forCode: "ja")!

    // MARK: - Builders

    /// A `SettingsStore` over isolated, in-memory defaults — home target 中文,
    /// secondary English (the first-read defaults), so the guard behaves as ship.
    private func makeSettings(_ preference: EnginePreference) -> SettingsStore {
        let suite = "TranslationServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults)
        settings.enginePreference = preference
        return settings
    }

    private func makeService(
        preference: EnginePreference,
        openAIKey: String?,
        detect: @escaping (String) async -> DetectedSource
    ) -> TranslationService {
        let session = MockURLProtocol.makeSession()
        let settings = makeSettings(preference)
        let resolver = EngineResolver(
            settings: settings, session: session, openAIKey: { openAIKey }
        )
        return TranslationService(
            resolver: resolver,
            settings: settings,
            detect: detect,
            makeGoogleFallback: { GoogleEngine(session: session, retryDelay: .zero) }
        )
    }

    /// A canned Google response: `[[["译文","src",…]], null, "<detected>"]`.
    private func googleBody(_ translation: String, detected: String? = "en") -> Data {
        let inner = [["\(translation)", "src", NSNull(), NSNull()] as [Any]]
        let root: [Any] = [inner, NSNull(), (detected as Any?) ?? NSNull()]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    // MARK: - Guard regressions (detect-first, one translate call)

    @Test("EN→中文: English source translates to 中文, no flip")
    func englishToChinese() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { req in (self.googleBody("你好"), MockURLProtocol.okResponse(for: req)) }

        let service = makeService(preference: .free, openAIKey: nil) { _ in
            .identified(self.english, confidence: nil)
        }
        let result = try await service.translate(
            text: "Hello", pair: LanguagePair(from: nil, to: chinese)
        )

        #expect(result.translation == "你好")
        #expect(result.detected == .identified(english, confidence: nil))
        #expect(result.servedBy == .free)
        #expect(result.viaGoogleFallback == false)
        // The single translate call went to 中文 (no guard flip).
        let items = Self.queryItems(MockURLProtocol.lastRequest)
        #expect(items["tl"] == "zh-CN")
    }

    @Test("中文→EN: Chinese source collides with the home target → guard flips to English")
    func chineseFlipsToEnglish() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { req in (self.googleBody("Hello"), MockURLProtocol.okResponse(for: req)) }

        let service = makeService(preference: .free, openAIKey: nil) { _ in
            .identified(self.chinese, confidence: nil)
        }
        let result = try await service.translate(
            text: "你好", pair: LanguagePair(from: nil, to: chinese)
        )

        #expect(result.translation == "Hello")
        // Detect-first means one translate call — straight to the flipped target.
        let items = Self.queryItems(MockURLProtocol.lastRequest)
        #expect(items["tl"] == "en")
    }

    @Test("JP→中文: Japanese source does not collide, so no flip")
    func japaneseNoFlip() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { req in (self.googleBody("你好"), MockURLProtocol.okResponse(for: req)) }

        let service = makeService(preference: .free, openAIKey: nil) { _ in
            .identified(self.japanese, confidence: nil)
        }
        let result = try await service.translate(
            text: "こんにちは", pair: LanguagePair(from: nil, to: chinese)
        )

        #expect(result.translation == "你好")
        #expect(result.detected == .identified(japanese, confidence: nil))
        let items = Self.queryItems(MockURLProtocol.lastRequest)
        #expect(items["tl"] == "zh-CN")
    }

    // MARK: - Runtime AI → Google safety net

    @Test("an AI translate failure retries on Google and flags viaGoogleFallback")
    func aiErrorFallsBackToGoogle() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        // OpenAI returns an error envelope; Google serves the fallback.
        MockURLProtocol.handler = { req in
            if req.url?.host == "api.openai.com" {
                return (Data(#"{"error":{"message":"boom"}}"#.utf8), MockURLProtocol.okResponse(for: req))
            }
            return (self.googleBody("你好"), MockURLProtocol.okResponse(for: req))
        }

        let service = makeService(preference: .openai, openAIKey: "sk-real-key") { _ in
            .identified(self.english, confidence: nil)
        }
        let result = try await service.translate(
            text: "Hello", pair: LanguagePair(from: nil, to: chinese)
        )

        #expect(result.translation == "你好")
        #expect(result.servedBy == .free)         // served by the Google retry
        #expect(result.viaGoogleFallback == true) // authoritative "via Google"
        #expect(result.detected == .identified(english, confidence: nil))
    }

    @Test("when both the AI engine and the Google retry fail, the error propagates")
    func bothEnginesFailPropagates() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        // OpenAI errors (fast, no retry); the Google retry is also down — nothing
        // left to fall back to, so the failure surfaces rather than being swallowed.
        MockURLProtocol.handler = { req in
            if req.url?.host == "api.openai.com" {
                return (Data(#"{"error":{"message":"boom"}}"#.utf8), MockURLProtocol.okResponse(for: req))
            }
            throw URLError(.notConnectedToInternet)
        }

        let service = makeService(preference: .openai, openAIKey: "sk-real-key") { _ in
            .identified(self.english, confidence: nil)
        }
        await #expect(throws: Error.self) {
            _ = try await service.translate(text: "Hello", pair: LanguagePair(from: nil, to: self.chinese))
        }
    }

    // MARK: - Helpers

    private static func queryItems(_ request: URLRequest?) -> [String: String] {
        guard let url = request?.url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems
        else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }
}
