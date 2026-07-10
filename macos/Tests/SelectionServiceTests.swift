import Foundation
import Testing
@testable import Translator_Everywhere

/// The `translateSelection` orchestration slice S4 owns (TECH §03·1, Fig. B1):
/// normalize → guard → window → route → deadline-wrapped engine call →
/// `SelectionResult`. The route is scripted through the `resolveSelection:`
/// init override, so card/plain/degraded outcomes need no Keychain and no
/// network; the degraded route is driven over `MockURLProtocol`.
/// QA rows I-01..I-08 (TECH §04, Table Q2).
@Suite("TranslationService.translateSelection — route, window, deadline, cancellation", .serialized)
struct SelectionServiceTests {

    private let chinese = LanguageCatalog.language(forCode: "zh-CN")!
    private let english = LanguageCatalog.language(forCode: "en")!

    private var pair: LanguagePair { LanguagePair(from: english, to: chinese) }

    // MARK: - Builders

    /// A `SettingsStore` over isolated, in-memory defaults (the
    /// TranslationServiceTests idiom) — selection never reads it, but the
    /// service init requires one.
    private func makeSettings() -> SettingsStore {
        let suite = "SelectionServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(defaults: defaults)
    }

    /// A service whose selection route is scripted. The detect / Google-fallback
    /// seams are inert on purpose: a selection request must never touch them.
    private func makeService(route: SelectionRoute, session: URLSession? = nil) -> TranslationService {
        let session = session ?? MockURLProtocol.makeSession()
        let settings = makeSettings()
        return TranslationService(
            resolver: EngineResolver(settings: settings, session: session, openAIKey: { nil }),
            settings: settings,
            detect: { _ in .unavailable },
            makeGoogleFallback: { GoogleEngine(session: session, retryDelay: .zero) },
            resolveSelection: { _ in route }
        )
    }

    /// A canned Google response: `[[["译文","src",…]], null, "<detected>"]`.
    private func googleBody(_ translation: String, detected: String? = "en") -> Data {
        let inner = [["\(translation)", "src", NSNull(), NSNull()] as [Any]]
        let root: [Any] = [inner, NSNull(), (detected as Any?) ?? NSNull()]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    // MARK: - I-01/I-02 · contextual route — output round-trip + mode decided once

    @Test("I-01: contextual route — card round-trips as .ai/contextUsed, stub sees .wordPhrase")
    func contextualCardRoute() async throws {
        let card = DictionaryCard(
            headword: "scored", translation: "攻入", partOfSpeech: "verb",
            sense: nil, example: nil, exampleTranslation: nil
        )
        let spy = SpySpanEngine(.yield(.card(card)))
        let service = makeService(route: .contextual(spy))

        let result = try await service.translateSelection(
            span: "scored", context: "Messi scored the final goal.", pair: pair
        )

        #expect(result == SelectionResult(output: .card(card), servedBy: .ai, contextUsed: true))
        #expect(await spy.modes == [.wordPhrase]) // mode decided in the service, once
        #expect(await spy.spans == ["scored"])
    }

    @Test("I-02: 5-token span — service decides .longSpan; .plain round-trips")
    func contextualLongSpanRoute() async throws {
        let spy = SpySpanEngine(.yield(.plain("梅西攻入了最后一球。")))
        let service = makeService(route: .contextual(spy))

        let result = try await service.translateSelection(
            span: "Messi scored the final goal.",
            context: "Messi scored the final goal. The crowd erupted.",
            pair: pair
        )

        #expect(result == SelectionResult(
            output: .plain("梅西攻入了最后一球。"), servedBy: .ai, contextUsed: true
        ))
        #expect(await spy.modes == [.longSpan]) // mode decided in the service, once
    }

    // MARK: - I-03 · degraded route — span-only Google, context-free flags

    @Test("I-03: degraded route — .plain via Google, .free, contextUsed false, span-only wire")
    func degradedGoogleRoute() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { req in (self.googleBody("攻入"), MockURLProtocol.okResponse(for: req)) }
        let session = MockURLProtocol.makeSession()
        let service = makeService(
            route: .contextFree(GoogleEngine(session: session, retryDelay: .zero)),
            session: session
        )

        let result = try await service.translateSelection(
            span: "scored", context: "Messi scored the final goal.", pair: pair
        )

        #expect(result == SelectionResult(output: .plain("攻入"), servedBy: .free, contextUsed: false))
        // The Google request carries the span only — no context leaks into the URL.
        let items = Self.queryItems(MockURLProtocol.lastRequest)
        #expect(items["q"] == "scored")
        #expect(items["sl"] == "en")     // pinned pair, no re-detect (deviation 1)
        #expect(items["tl"] == "zh-CN")
        let url = MockURLProtocol.lastRequest?.url?.absoluteString ?? ""
        #expect(!url.contains("final"), "context text must not leak into the degraded request")
    }

    // MARK: - I-04 · context is windowed before the engine sees it

    @Test("I-04: context > 1500 chars — the engine sees the windowed slice, not the full text")
    func oversizedContextIsWindowed() async throws {
        let spy = SpySpanEngine(.yield(.plain("x")))
        let service = makeService(route: .contextual(spy))
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 60) // ~1620 chars a side
        let context = filler + "Messi scored the final goal. " + filler

        _ = try await service.translateSelection(span: "scored", context: context, pair: pair)

        let seen = try #require(await spy.contexts.first)
        #expect(seen.count <= SelectionPolicy.maxContextChars)
        #expect(seen.contains("scored"))
        #expect(seen != context)
    }

    // MARK: - I-05 · no runtime AI→Google fallback for selections

    @Test("I-05: contextual failure rethrows — zero Google traffic (backend deviation 2)")
    func contextualFailureDoesNotFallBackToGoogle() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        // Watch for ANY traffic: a fallback attempt would register here.
        MockURLProtocol.handler = { req in (self.googleBody("nope"), MockURLProtocol.okResponse(for: req)) }
        let spy = SpySpanEngine(.fail(TranslationError.network(engine: .ai, underlying: nil)))
        let service = makeService(route: .contextual(spy))

        do {
            _ = try await service.translateSelection(
                span: "scored", context: "Messi scored the final goal.", pair: pair
            )
            Issue.record("expected .network to rethrow")
        } catch let error as TranslationError {
            guard case let .network(engine, _) = error else {
                Issue.record("unexpected TranslationError: \(error)")
                return
            }
            #expect(engine == .ai)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(MockURLProtocol.lastRequest == nil, "no runtime AI→Google fallback for selections")
    }

    // MARK: - I-06 · deadline

    @Test("I-06: hung engine + injected 50 ms deadline throws .timedOut within the test budget")
    func hungEngineTimesOut() async {
        let spy = SpySpanEngine(.hang)
        let service = makeService(route: .contextual(spy))
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await service.translateSelection(
                span: "scored", context: "Messi scored the final goal.", pair: pair,
                timeout: .milliseconds(50)
            )
            Issue.record("expected .timedOut")
        } catch let error as TranslationError {
            guard case .timedOut = error else {
                Issue.record("unexpected TranslationError: \(error)")
                return
            }
        } catch is CancellationError {
            Issue.record("a timeout must surface as .timedOut, never CancellationError")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        // Generous bound — proves the 50 ms deadline governed, not the 8 s default.
        #expect(clock.now - start < .seconds(4))
    }

    // MARK: - I-07 · cancellation passthrough

    @Test("I-07: cancelling the wrapping Task mid-flight rethrows CancellationError as-is")
    func cancellationRethrownAsIs() async {
        let spy = SpySpanEngine(.hang)
        let service = makeService(route: .contextual(spy))

        let task = Task {
            try await service.translateSelection(
                span: "scored", context: "Messi scored the final goal.", pair: pair
            )
        }
        await spy.waitUntilInFlight()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // Rethrown untouched — never wrapped into .network/.timedOut; the
            // coordinator's .superseded mapping depends on this (AC-7).
        } catch {
            Issue.record("cancellation must not be wrapped: \(error)")
        }
    }

    // MARK: - I-08 · empty-span guard

    @Test("I-08: span normalizing to \"\" throws .emptyInput before any engine call")
    func emptySpanThrowsBeforeEngineCall() async {
        let spy = SpySpanEngine(.yield(.plain("never")))
        let service = makeService(route: .contextual(spy))

        do {
            _ = try await service.translateSelection(
                span: "  \n\t  ", context: "Messi scored the final goal.", pair: pair
            )
            Issue.record("expected .emptyInput")
        } catch let error as TranslationError {
            guard case .emptyInput = error else {
                Issue.record("unexpected TranslationError: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(await spy.spans.isEmpty, "no engine call for an empty span (defensive — UI already guards)")
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

/// A scripted `SelectionSpanTranslating` spy — records every call's arguments
/// so routing tests can assert the span/context/mode the service decided. An
/// `actor` to serialize recording (the GatedService idiom).
private actor SpySpanEngine: SelectionSpanTranslating {
    enum Behavior {
        case yield(SelectionOutput)
        case fail(any Error)
        /// Parks on a long *cancellable* sleep — a hung engine that still
        /// observes cancellation, like the real engines' retry loops.
        case hang
    }

    private let behavior: Behavior
    private(set) var spans: [String] = []
    private(set) var contexts: [String] = []
    private(set) var modes: [SelectionMode] = []
    private var inFlightSignal: CheckedContinuation<Void, Never>?
    private var isInFlight = false

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func translateSpan(span: String, context: String,
                       pair: LanguagePair, mode: SelectionMode) async throws -> SelectionOutput {
        spans.append(span)
        contexts.append(context)
        modes.append(mode)
        isInFlight = true
        inFlightSignal?.resume()
        inFlightSignal = nil

        switch behavior {
        case let .yield(output):
            return output
        case let .fail(error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(300)) // cancellable park
            throw TranslationError.network(engine: .ai, underlying: nil)
        }
    }

    /// Suspends until `translateSpan` has been entered, so a test can cancel
    /// provably mid-flight.
    func waitUntilInFlight() async {
        if isInFlight { return }
        await withCheckedContinuation { inFlightSignal = $0 }
    }
}
