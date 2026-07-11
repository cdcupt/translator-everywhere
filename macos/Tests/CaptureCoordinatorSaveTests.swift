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

    // MARK: - Selection lookups (slice S7): two-token guard + hooks wiring

    /// I-09 (AC-7 · FR-1) — the A/B supersede race: request A ("scored") parks
    /// in-flight behind the stub's gate; B ("final goal") fires after it and
    /// completes at once; then the gate opens and A returns late. B owns the
    /// slot (`.success`); late A is dropped (`.superseded`); and the panel
    /// never saw an A render — the coordinator returns outcomes, presents nothing.
    @Test("I-09: a newer selection lookup supersedes the older in-flight one")
    func selectionRaceDropsLateReturn() async throws {
        let zh = try #require(LanguageCatalog.language(forCode: "zh-CN"))
        let pair = LanguagePair(from: nil, to: zh)
        let service = GatedSelectionService(
            slowSpan: "scored",
            translations: ["scored": "攻入（进球）", "final goal": "决胜球"]
        )
        let spy = SpyResultPanel()
        let coordinator = CaptureCoordinator(
            settings: makeSettings(), service: service, resultPanel: spy, notebook: nil
        )

        // A bumps the selection token, then parks in-flight (gate closed).
        let a = Task {
            await coordinator.translateSelectionLatest(
                span: "scored", context: "He scored twice tonight.", pair: pair
            )
        }
        await service.waitUntilParked()

        // B fires after its own settle and completes fast — it is now the newest.
        let b = await coordinator.translateSelectionLatest(
            span: "final goal", context: "The final goal stood.", pair: pair
        )
        guard case let .success(result) = b else {
            Issue.record("expected the newer selection lookup to succeed")
            return
        }
        #expect(result.output == .plain("决胜球"))

        // The gate opens: A returns late with a stale selection token.
        await service.openGate()
        guard case .superseded = await a.value else {
            Issue.record("expected the older selection lookup to be superseded")
            return
        }
        // The panel saw no A render — no render at all: outcomes are the
        // panel's to apply, and nothing was presented for either request.
        #expect(spy.events.isEmpty)
    }

    /// I-10 (AC-5 · FR-6) — cross-token staleness: a new capture/retranslate
    /// (`runTranslation`) bumps the MAIN generation while a selection lookup is
    /// in flight; when the lookup returns, its captured main token no longer
    /// matches → `.superseded`. A stale card can never ride over new content.
    @Test("I-10: a main-generation bump mid-flight supersedes the selection lookup")
    func selectionSupersededByNewCapture() async throws {
        let zh = try #require(LanguageCatalog.language(forCode: "zh-CN"))
        let pair = LanguagePair(from: nil, to: zh)
        let service = GatedSelectionService(slowSpan: "scored", translations: ["scored": "攻入"])
        let coordinator = CaptureCoordinator(
            settings: makeSettings(), service: service, resultPanel: SpyResultPanel(), notebook: nil
        )

        // The selection lookup parks in-flight, its main token captured.
        let lookup = Task {
            await coordinator.translateSelectionLatest(
                span: "scored", context: "He scored twice.", pair: pair
            )
        }
        await service.waitUntilParked()

        // A new capture translates — the main generation moves on.
        await coordinator.runTranslation(text: "fresh capture", pair: pair)

        // The parked lookup returns to a changed main token → superseded, even
        // though no newer SELECTION ever started.
        await service.openGate()
        guard case .superseded = await lookup.value else {
            Issue.record("expected the selection lookup to be superseded by the new capture")
            return
        }
    }

    /// I-11 (AC-7 · FR-6, tightened in beta round 2 / F1) — outcome mapping
    /// preserves the error taxonomy by the LOOKUP's fate, not the error's
    /// spelling:
    /// (a) a lookup whose task was really cancelled (the panel superseded or
    ///     dismissed it) → `.superseded`;
    /// (b) a `CancellationError` surfacing in a lookup NOBODY cancelled is a
    ///     real failure — mapping it to `.superseded` renders nothing and the
    ///     skeleton shimmers forever (the live N10 silent-failure defect);
    /// (c) `TranslationError.timedOut` → `.failure(.timedOut)` so the panel
    ///     renders the quiet error row.
    @Test("I-11: only a really-cancelled lookup is superseded; a stray CancellationError and a timeout are failures")
    func selectionOutcomeMapping() async throws {
        let zh = try #require(LanguageCatalog.language(forCode: "zh-CN"))
        let pair = LanguagePair(from: nil, to: zh)

        // (a) a genuinely cancelled lookup → .superseded. The service parks on
        // a cancellation-responsive sleep; cancelling the wrapping task is the
        // only thing that resolves it.
        let parked = CaptureCoordinator(
            settings: makeSettings(),
            service: SleepingSelectionService(),
            resultPanel: SpyResultPanel(), notebook: nil
        )
        let lookup = Task {
            await parked.translateSelectionLatest(span: "scored", context: "ctx", pair: pair)
        }
        lookup.cancel()
        guard case .superseded = await lookup.value else {
            Issue.record("expected a really-cancelled lookup to map to .superseded")
            return
        }

        // (b) a CancellationError thrown by the stack in a NON-cancelled
        // lookup → .failure (the error row must render — never a silent void).
        let stray = CaptureCoordinator(
            settings: makeSettings(),
            service: ThrowingSelectionService(error: CancellationError()),
            resultPanel: SpyResultPanel(), notebook: nil
        )
        let b = await stray.translateSelectionLatest(span: "scored", context: "ctx", pair: pair)
        guard case .failure = b else {
            Issue.record("expected a stray CancellationError in a live lookup to surface as .failure")
            return
        }

        // (c) timeout → .failure(.timedOut)
        let timedOut = CaptureCoordinator(
            settings: makeSettings(),
            service: ThrowingSelectionService(error: TranslationError.timedOut),
            resultPanel: SpyResultPanel(), notebook: nil
        )
        let c = await timedOut.translateSelectionLatest(span: "scored", context: "ctx", pair: pair)
        guard case let .failure(error) = c, case TranslationError.timedOut = error else {
            Issue.record("expected a timeout to surface as .failure(.timedOut)")
            return
        }
    }

    /// I-12 (FR-2 · FR-7) — hooks wiring: `present` hands the panel ONE
    /// `SelectionHooks` whose translate closure forwards the span verbatim,
    /// the capture's recognized text as context, and the PINNED pair — the
    /// explicit From when set, else the detected language, else Auto — with
    /// `effectiveTo` as target. No notebook ⇒ the save hook is nil.
    @Test("I-12: the translate hook forwards span verbatim, recognized text as context, and the pinned pair")
    func selectionHooksWiring() async throws {
        let en = try #require(LanguageCatalog.language(forCode: "en"))
        let zh = try #require(LanguageCatalog.language(forCode: "zh-CN"))
        let fr = try #require(LanguageCatalog.language(forCode: "fr"))

        // Pinning step 2 — no explicit From: the DETECTED language is pinned.
        let detected = RecordingSelectionService(result: TranslationResult(
            translation: "他梅开二度", detected: .identified(en, confidence: 0.97),
            servedBy: .ai, viaGoogleFallback: false, effectiveTo: zh
        ))
        let spy = SpyResultPanel()
        let coordinator = CaptureCoordinator(
            settings: makeSettings(), service: detected, resultPanel: spy, notebook: nil
        )
        await coordinator.runTranslation(
            text: "He scored twice tonight.", pair: LanguagePair(from: nil, to: zh)
        )
        let hooks = try #require(spy.lastSelection)
        #expect(hooks.save == nil)
        guard case .success = await hooks.translate("scored") else {
            Issue.record("expected the translate hook to succeed")
            return
        }
        #expect(await detected.recordedSpan == "scored")
        #expect(await detected.recordedContext == "He scored twice tonight.")
        let pinned = try #require(await detected.recordedPair)
        #expect(pinned.from?.code == "en")
        #expect(pinned.to.code == "zh-CN")

        // Pinning step 1 — an explicit From wins over the detected language.
        let explicit = RecordingSelectionService(result: TranslationResult(
            translation: "他进球了", detected: .identified(en, confidence: 0.97),
            servedBy: .ai, viaGoogleFallback: false, effectiveTo: zh
        ))
        let explicitSpy = SpyResultPanel()
        let explicitCoordinator = CaptureCoordinator(
            settings: makeSettings(), service: explicit, resultPanel: explicitSpy, notebook: nil
        )
        await explicitCoordinator.runTranslation(
            text: "Il a marqué.", pair: LanguagePair(from: fr, to: zh)
        )
        _ = await (try #require(explicitSpy.lastSelection)).translate("marqué")
        let explicitPinned = try #require(await explicit.recordedPair)
        #expect(explicitPinned.from?.code == "fr")
        #expect(explicitPinned.to.code == "zh-CN")

        // Pinning step 3 — neither explicit nor detected: Auto (nil From).
        let auto = RecordingSelectionService(result: TranslationResult(
            translation: "他进球了", detected: .unavailable,
            servedBy: .ai, viaGoogleFallback: false, effectiveTo: zh
        ))
        let autoSpy = SpyResultPanel()
        let autoCoordinator = CaptureCoordinator(
            settings: makeSettings(), service: auto, resultPanel: autoSpy, notebook: nil
        )
        await autoCoordinator.runTranslation(
            text: "He scored.", pair: LanguagePair(from: nil, to: zh)
        )
        _ = await (try #require(autoSpy.lastSelection)).translate("scored")
        let autoPinned = try #require(await auto.recordedPair)
        #expect(autoPinned.from == nil)
        #expect(autoPinned.to.code == "zh-CN")
    }

    /// U-32 (FR-7 · AC-6) — a card save lands exactly one row through the
    /// EXISTING save path: span as `sourceText`, the card translation, the
    /// capture's threaded from/to codes, engine="ai" — no new fields touched.
    @Test("U-32: hooks.save writes span/translation with threaded codes and engine=ai")
    func cardSaveWritesThreadedRow() async throws {
        let en = try #require(LanguageCatalog.language(forCode: "en"))
        let zh = try #require(LanguageCatalog.language(forCode: "zh-CN"))
        let store = try NotebookStore(inMemory: true)
        let result = TranslationResult(
            translation: "他梅开二度", detected: .identified(en, confidence: 0.97),
            servedBy: .ai, viaGoogleFallback: false, effectiveTo: zh
        )
        let spy = SpyResultPanel()
        let coordinator = CaptureCoordinator(
            settings: makeSettings(), service: StubTranslating(result: result),
            resultPanel: spy, notebook: store
        )
        await coordinator.runTranslation(
            text: "He scored twice.", pair: LanguagePair(from: nil, to: zh)
        )

        let hooks = try #require(spy.lastSelection)
        let save = try #require(hooks.save)
        #expect(await save("scored", "攻入（进球）", .ai))

        let all = try store.all()
        #expect(all.count == 1)
        let row = try #require(all.first)
        #expect(row.sourceText == "scored")
        #expect(row.translation == "攻入（进球）")
        #expect(row.srcLang == "en")     // the capture's detected code, threaded
        #expect(row.tgtLang == "zh-CN")  // the capture's effective target, threaded
        #expect(row.engine == EngineKind.ai.rawValue)
    }

    /// U-33 (FR-5 · FR-7) — the degraded variant saves honestly: a card served
    /// by Google records engine="free", so the notebook badge stays truthful.
    @Test("U-33: a degraded card save records engine=free")
    func degradedCardSaveRecordsFreeEngine() async throws {
        let en = try #require(LanguageCatalog.language(forCode: "en"))
        let zh = try #require(LanguageCatalog.language(forCode: "zh-CN"))
        let store = try NotebookStore(inMemory: true)
        let result = TranslationResult(
            translation: "他梅开二度", detected: .identified(en, confidence: 0.97),
            servedBy: .free, viaGoogleFallback: false, effectiveTo: zh
        )
        let spy = SpyResultPanel()
        let coordinator = CaptureCoordinator(
            settings: makeSettings(), service: StubTranslating(result: result),
            resultPanel: spy, notebook: store
        )
        await coordinator.runTranslation(
            text: "He scored twice.", pair: LanguagePair(from: nil, to: zh)
        )

        let hooks = try #require(spy.lastSelection)
        let save = try #require(hooks.save)
        #expect(await save("scored", "攻入", .free))

        let row = try #require(try store.all().first)
        #expect(row.engine == EngineKind.free.rawValue)
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

    /// Mechanical `Translating` conformance (TECH §03·1) — selection is not
    /// under test here, so the stub answers with a plain degraded shape.
    func translateSelection(span: String, context: String, pair: LanguagePair) async throws -> SelectionResult {
        SelectionResult(
            output: .plain(translations[pair.to.code] ?? "?"),
            servedBy: .free,
            contextUsed: false
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

/// A `Translating` stub whose SELECTION path parks a configured span until the
/// test opens its gate, so the selection A/B race (I-09) and the cross-token
/// staleness (I-10) are deterministic — no sleeps. Mirrors `GatedService`; its
/// main `translate` returns at once so `runTranslation` can bump the main
/// generation while a selection lookup is parked.
private actor GatedSelectionService: Translating {
    private let slowSpan: String
    private let translations: [String: String]
    private var release: CheckedContinuation<Void, Never>?
    private var parkedSignal: CheckedContinuation<Void, Never>?
    private var isParked = false

    init(slowSpan: String, translations: [String: String]) {
        self.slowSpan = slowSpan
        self.translations = translations
    }

    func translate(text: String, pair: LanguagePair) async throws -> TranslationResult {
        TranslationResult(
            translation: "T", detected: .unavailable, servedBy: .free,
            viaGoogleFallback: false, effectiveTo: pair.to
        )
    }

    func translateSelection(span: String, context: String, pair: LanguagePair) async throws -> SelectionResult {
        if span == slowSpan {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                release = cont
                isParked = true
                parkedSignal?.resume()
                parkedSignal = nil
            }
        }
        return SelectionResult(
            output: .plain(translations[span] ?? "?"), servedBy: .ai, contextUsed: true
        )
    }

    /// Suspends until the slow selection lookup has parked on its gate.
    func waitUntilParked() async {
        if isParked { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            parkedSignal = cont
        }
    }

    /// Releases the parked selection lookup.
    func openGate() {
        release?.resume()
        release = nil
    }
}

/// A `Translating` stub whose selection path always throws, so the outcome
/// mapping (I-11) can be asserted directly.
private struct ThrowingSelectionService: Translating {
    let error: any Error
    func translate(text: String, pair: LanguagePair) async throws -> TranslationResult { throw error }
    func translateSelection(span: String, context: String, pair: LanguagePair) async throws -> SelectionResult { throw error }
}

/// A `Translating` stub whose selection path parks on a CANCELLATION-RESPONSIVE
/// sleep — cancelling the wrapping task is the only thing that resolves it, so
/// I-11 (a) can assert the really-cancelled → `.superseded` mapping without
/// wall-clock flakiness.
private struct SleepingSelectionService: Translating {
    func translate(text: String, pair: LanguagePair) async throws -> TranslationResult {
        throw TranslationError.emptyInput
    }
    func translateSelection(span: String, context: String, pair: LanguagePair) async throws -> SelectionResult {
        try await Task.sleep(for: .seconds(300))
        throw TranslationError.timedOut
    }
}

/// A `Translating` stub that returns a fixed main result and RECORDS the
/// selection arguments the coordinator's hook forwards (I-12): the span, the
/// context, and the pinned pair.
private actor RecordingSelectionService: Translating {
    private let result: TranslationResult
    private(set) var recordedSpan: String?
    private(set) var recordedContext: String?
    private(set) var recordedPair: LanguagePair?

    init(result: TranslationResult) {
        self.result = result
    }

    func translate(text: String, pair: LanguagePair) async throws -> TranslationResult { result }

    func translateSelection(span: String, context: String, pair: LanguagePair) async throws -> SelectionResult {
        recordedSpan = span
        recordedContext = context
        recordedPair = pair
        return SelectionResult(output: .plain("記録"), servedBy: .ai, contextUsed: true)
    }
}

/// A `Translating` stub that returns a fixed result, so the coordinator's present
/// composition (effective-target display + threaded save codes) can be asserted
/// without the network.
private struct StubTranslating: Translating {
    let result: TranslationResult
    func translate(text: String, pair: LanguagePair) async throws -> TranslationResult { result }

    /// Mechanical `Translating` conformance (TECH §03·1) — echoes the fixed
    /// translation as a plain degraded shape; selection is not under test here.
    func translateSelection(span: String, context: String, pair: LanguagePair) async throws -> SelectionResult {
        SelectionResult(output: .plain(result.translation), servedBy: result.servedBy, contextUsed: false)
    }
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
    private(set) var lastSelection: SelectionHooks?

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
        onRetranslate: (@MainActor (LanguagePair) -> Void)?,
        selection: SelectionHooks?
    ) {
        lastTranslation = translation
        lastPair = pair
        lastDetected = detected
        lastOnSave = onSave
        lastSelection = selection
        events.append(.result(translation: translation))
    }

    func showTranslating(source: String?) {
        events.append(.translating(source: source))
    }

    func showError(title: String, message: String) { events.append(.error) }
    func show(title: String, body: String) { events.append(.message) }
}
