import Foundation
import Testing
@testable import Translator_Everywhere

/// Opt-in notebook saving + the orchestration the coordinator owns after slice 6.
///
/// A capture must NOT write to the notebook on its own; only the panel's Save
/// handler — `CaptureCoordinator.save` — persists, and exactly once, threading
/// the resolved From/To codes into the row. These tests drive the save handler
/// and the generation-guarded translate core directly (the interim
/// `translateWithGuard` is gone — its EN⇄ZH regression now lives in
/// `TranslationServiceTests`).
@MainActor
@Suite("CaptureCoordinator — opt-in save + generation token", .serialized)
struct CaptureCoordinatorSaveTests {

    private func makeCoordinator(notebook: NotebookStore?) -> CaptureCoordinator {
        CaptureCoordinator(resultPanel: ResultPanel(), notebook: notebook)
    }

    /// An isolated, in-memory `SettingsStore` so a test never touches real defaults.
    private func makeSettings() -> SettingsStore {
        let suite = "CaptureCoordinatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(defaults: defaults)
    }

    @Test("building a coordinator does not write to the notebook")
    func noWriteWithoutSave() async throws {
        let store = try NotebookStore(inMemory: true)
        _ = makeCoordinator(notebook: store)

        // No capture → no Save click → the notebook stays empty.
        #expect(try store.all().isEmpty)
    }

    @Test("invoking the save handler writes exactly one entry with threaded codes")
    func saveHandlerWritesOnce() async throws {
        let store = try NotebookStore(inMemory: true)
        let coordinator = makeCoordinator(notebook: store)

        let ok = await coordinator.save(
            source: "Exit", translation: "出口", from: "en", to: "zh-CN", kind: .free
        )

        #expect(ok)
        let all = try store.all()
        #expect(all.count == 1)
        #expect(all.first?.sourceText == "Exit")
        #expect(all.first?.translation == "出口")
        #expect(all.first?.srcLang == "en")
        #expect(all.first?.tgtLang == "zh-CN")
        #expect(all.first?.engine == EngineKind.free.rawValue)
    }

    @Test("each save handler call persists its own capture")
    func saveHandlerPersistsEachCall() async throws {
        let store = try NotebookStore(inMemory: true)
        let coordinator = makeCoordinator(notebook: store)

        _ = await coordinator.save(source: "one", translation: "一", from: "en", to: "zh-CN", kind: .free)
        _ = await coordinator.save(source: "two", translation: "二", from: "zh-CN", to: "en", kind: .ai)

        #expect(try store.all().count == 2)
    }

    @Test("save handler is a no-op (false) when there is no notebook")
    func saveWithoutNotebook() async throws {
        let coordinator = makeCoordinator(notebook: nil)

        let ok = await coordinator.save(
            source: "x", translation: "y", from: "en", to: "zh-CN", kind: .free
        )

        // No store → the panel offers no Save button; a defensive call reports
        // failure rather than crashing.
        #expect(!ok)
    }

    // MARK: - Effective target threaded to the panel (the pre-merge HIGH bug)

    /// The blocker: on the default config (home zh-CN, secondary en, last-used
    /// Auto→zh-CN), a Chinese capture is translated to English (the guard flips
    /// zh→en), but the coordinator used to hand the panel the *raw* requested pair
    /// — so the bar showed "To: 中文" and a ⇄ swap composed a degenerate ZH→ZH.
    /// This asserts the displayed target == the translated target == the notebook
    /// tgtLang (English), and that a swap from the effective pair composes EN↔ZH.
    @Test("a Chinese capture on the default config displays the effective target (English) and swaps EN↔ZH")
    func chineseCaptureThreadsEffectiveTargetToPanel() async throws {
        let zh = LanguageCatalog.language(forCode: "zh-CN")!
        let en = LanguageCatalog.language(forCode: "en")!

        // Default config: the requested pair is Auto→中文; the guard flipped to en.
        let settings = makeSettings()
        let requested = settings.lastUsedPair
        #expect(requested.from == nil)
        #expect(requested.to.code == "zh-CN")

        let result = TranslationResult(
            translation: "Hello", detected: .identified(zh, confidence: 0.99),
            servedBy: .free, viaGoogleFallback: false, effectiveTo: en
        )
        let spy = SpyResultPanel()
        let notebook = try NotebookStore(inMemory: true)
        let coordinator = CaptureCoordinator(
            settings: settings, service: StubTranslating(result: result),
            resultPanel: spy, notebook: notebook
        )

        await coordinator.runTranslation(text: "你好", pair: requested)

        // Displayed target == the translated target (English), NOT the pre-guard 中文.
        let shown = try #require(spy.lastPair)
        #expect(shown.to.code == "en")
        #expect(shown.to.code == result.effectiveTo.code)
        #expect(shown.from == nil)

        // Notebook tgtLang == the translated target; detected source threaded as srcLang.
        let onSave = try #require(spy.lastOnSave)
        #expect(await onSave())
        let row = try #require(try notebook.all().first)
        #expect(row.tgtLang == "en")
        #expect(row.srcLang == "zh-CN")

        // A ⇄ swap from the effective pair composes EN→ZH (NOT a degenerate ZH→ZH).
        let detected = try #require(spy.lastDetected)
        let bar = LanguageBarController(pair: shown, detected: detected, recentProvider: { [] })
        var swapped: LanguagePair?
        bar.onPick = { swapped = $0 }
        bar.languageBarDidTapSwap(LanguageBarView())
        let swap = try #require(swapped)
        #expect(swap.from?.code == "en")
        #expect(swap.to.code == "zh-CN")
    }

    // MARK: - Instant loading panel (UX: no dead air before the result)

    /// The UX fix: a capture must show the panel *immediately* in a loading state,
    /// before OCR + the (now network-bound) translation run, then fill it in place.
    /// Drives the full `captureAndTranslate` with injected permission/capturer/OCR
    /// seams and asserts the ordering: `showTranslating(source: nil)` first, the
    /// recognized text reaching the panel after OCR, and the real result last.
    @Test("a capture shows the loading panel before the result, filling recognized text then translation")
    func captureShowsLoadingBeforeResult() async throws {
        let en = try #require(LanguageCatalog.language(forCode: "en"))
        let zh = try #require(LanguageCatalog.language(forCode: "zh-CN"))
        let result = TranslationResult(
            translation: "出口", detected: .identified(en, confidence: 0.99),
            servedBy: .free, viaGoogleFallback: false, effectiveTo: zh
        )

        let spy = SpyResultPanel()
        // A capturer that "completes" by writing a file to the destination, so
        // `captureRegion` returns a non-nil URL (cancel = no file).
        let capturer = RegionCapturer { url in try Data().write(to: url) }
        // An OCR seam that returns fixed recognized text without driving Vision.
        let ocr = OCRService(recognize: { _ in "Exit" })
        let coordinator = CaptureCoordinator(
            permission: PermissionService(isGranted: true),
            capturer: capturer,
            ocr: ocr,
            settings: makeSettings(),
            service: StubTranslating(result: result),
            resultPanel: spy,
            notebook: nil
        )

        await coordinator.captureAndTranslate()

        // The instant loading state (no source yet) is the very first thing shown.
        #expect(spy.events.first == .translating(source: nil))
        // After OCR the recognized text reaches the panel, still in the loading state.
        #expect(spy.events.contains(.translating(source: "Exit")))
        // The real result is the last thing shown — it supersedes the loading state.
        #expect(spy.events.last == .result(translation: "出口"))
        #expect(spy.lastTranslation == "出口")

        // Ordering: loading (nil) → recognized (source) → result, strictly.
        let loadingIdx = try #require(spy.events.firstIndex(of: .translating(source: nil)))
        let recognizedIdx = try #require(spy.events.firstIndex(of: .translating(source: "Exit")))
        let resultIdx = try #require(spy.events.firstIndex(of: .result(translation: "出口")))
        #expect(loadingIdx < recognizedIdx)
        #expect(recognizedIdx < resultIdx)
    }

    // MARK: - Generation token (out-of-order result suppression)

    @Test("an older slow result is dropped when a newer request starts")
    func generationTokenDropsStaleResult() async throws {
        let zh = LanguageCatalog.language(forCode: "zh-CN")!
        let ja = LanguageCatalog.language(forCode: "ja")!
        let service = GatedService(
            slowTargetCode: ja.code,
            translations: [ja.code: "SLOW", zh.code: "FAST"]
        )
        let coordinator = CaptureCoordinator(
            settings: makeSettings(), service: service, resultPanel: ResultPanel(), notebook: nil
        )

        // Older request: To = ja (slow). It bumps the token, then parks in-flight.
        let slow = Task {
            await coordinator.translateLatest(text: "x", pair: LanguagePair(from: nil, to: ja))
        }
        await service.waitUntilParked()

        // Newer request: To = zh (fast). It becomes the newest and returns at once.
        let fast = await coordinator.translateLatest(text: "x", pair: LanguagePair(from: nil, to: zh))
        guard case let .success(fastResult) = fast else {
            Issue.record("expected the newer request to succeed")
            return
        }
        #expect(fastResult.translation == "FAST")

        // Release the older one: its token is now stale, so it must be superseded.
        await service.openGate()
        let slowOutcome = await slow.value
        guard case .superseded = slowOutcome else {
            Issue.record("expected the older, slower result to be dropped as superseded")
            return
        }
    }
}

/// A `Translating` stub that parks the "slow" target until the test opens its
/// gate, so the generation-token race is deterministic (no sleeps). An `actor`
/// to serialize the gate/park continuations.
private actor GatedService: Translating {
    private let slowTargetCode: String
    private let translations: [String: String]
    private var release: CheckedContinuation<Void, Never>?
    private var parkedSignal: CheckedContinuation<Void, Never>?
    private var isParked = false

    init(slowTargetCode: String, translations: [String: String]) {
        self.slowTargetCode = slowTargetCode
        self.translations = translations
    }

    func translate(text: String, pair: LanguagePair) async throws -> TranslationResult {
        if pair.to.code == slowTargetCode {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                release = cont
                isParked = true
                parkedSignal?.resume()
                parkedSignal = nil
            }
        }
        return TranslationResult(
            translation: translations[pair.to.code] ?? "?",
            detected: .unavailable,
            servedBy: .free,
            viaGoogleFallback: false,
            effectiveTo: pair.to
        )
    }

    /// Suspends until the slow translate has parked on its gate.
    func waitUntilParked() async {
        if isParked { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            parkedSignal = cont
        }
    }

    /// Releases the parked slow translate.
    func openGate() {
        release?.resume()
        release = nil
    }
}

/// A `Translating` stub that returns a fixed result, so the coordinator's present
/// composition (effective-target display + threaded save codes) can be asserted
/// without the network.
private struct StubTranslating: Translating {
    let result: TranslationResult
    func translate(text: String, pair: LanguagePair) async throws -> TranslationResult { result }
}

/// A `ResultPresenting` spy that records the pair/detection/save-hook handed to
/// the panel, so the test can assert what the bar would render and what a Save
/// would persist — without mounting AppKit. Also records an ordered event log so
/// the capture flow's loading-before-result sequence can be asserted.
@MainActor
private final class SpyResultPanel: ResultPresenting {
    private(set) var lastTranslation: String?
    private(set) var lastPair: LanguagePair?
    private(set) var lastDetected: DetectedSource?
    private(set) var lastOnSave: (@MainActor () async -> Bool)?

    /// The presentation calls in order, so a test can assert that the instant
    /// loading state is shown before the result fills it in.
    enum Event: Equatable {
        case translating(source: String?)
        case result(translation: String)
        case error
        case message
    }
    private(set) var events: [Event] = []

    func showResult(
        translation: String,
        source: String,
        badge: String,
        copied: Bool,
        pair: LanguagePair?,
        detected: DetectedSource,
        viaGoogleFallback: Bool,
        onSave: (@MainActor () async -> Bool)?,
        onRetranslate: (@MainActor (LanguagePair) -> Void)?
    ) {
        lastTranslation = translation
        lastPair = pair
        lastDetected = detected
        lastOnSave = onSave
        events.append(.result(translation: translation))
    }

    func showTranslating(source: String?) {
        events.append(.translating(source: source))
    }

    func showError(title: String, message: String) { events.append(.error) }
    func show(title: String, body: String) { events.append(.message) }
}
