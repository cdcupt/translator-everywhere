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
            viaGoogleFallback: false
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
