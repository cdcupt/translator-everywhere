import Foundation
import Testing
@testable import Translator_Everywhere

/// Opt-in notebook saving (DESIGN — Save-to-Notebook button replaces auto-save).
///
/// A capture must NOT write to the notebook on its own; only the panel's Save
/// handler — `CaptureCoordinator.save` — persists, and exactly once. These tests
/// drive the save handler directly (the same closure the result panel's button
/// invokes) against an in-memory store, replacing the previous auto-save
/// coverage that asserted a write happened during the capture itself.
@MainActor
@Suite("CaptureCoordinator — opt-in notebook save", .serialized)
struct CaptureCoordinatorSaveTests {

    private func makeCoordinator(notebook: NotebookStore?) -> CaptureCoordinator {
        CaptureCoordinator(resultPanel: ResultPanel(), notebook: notebook)
    }

    @Test("building a coordinator does not write to the notebook")
    func noWriteWithoutSave() async throws {
        let store = try NotebookStore(inMemory: true)
        _ = makeCoordinator(notebook: store)

        // No capture → no Save click → the notebook stays empty. (Previously a
        // capture auto-saved; now nothing is written until the user opts in.)
        #expect(try store.all().isEmpty)
    }

    @Test("invoking the save handler writes exactly one entry")
    func saveHandlerWritesOnce() async throws {
        let store = try NotebookStore(inMemory: true)
        let coordinator = makeCoordinator(notebook: store)

        let ok = await coordinator.save(source: "Exit", translation: "出口", kind: .free)

        #expect(ok)
        let all = try store.all()
        #expect(all.count == 1)
        #expect(all.first?.sourceText == "Exit")
        #expect(all.first?.translation == "出口")
        #expect(all.first?.engine == EngineKind.free.rawValue)
    }

    @Test("each save handler call persists its own capture")
    func saveHandlerPersistsEachCall() async throws {
        let store = try NotebookStore(inMemory: true)
        let coordinator = makeCoordinator(notebook: store)

        _ = await coordinator.save(source: "one", translation: "一", kind: .free)
        _ = await coordinator.save(source: "two", translation: "二", kind: .ai)

        #expect(try store.all().count == 2)
    }

    @Test("save handler is a no-op (false) when there is no notebook")
    func saveWithoutNotebook() async throws {
        let coordinator = makeCoordinator(notebook: nil)

        let ok = await coordinator.save(source: "x", translation: "y", kind: .free)

        // No store → the panel offers no Save button; a defensive call reports
        // failure rather than crashing.
        #expect(!ok)
    }

    // MARK: - Interim EN⇄ZH guard wiring (slice 3 — preserved end-to-end)

    private static let chinese = LanguageCatalog.language(forCode: "zh-CN")!
    private static let english = LanguageCatalog.language(forCode: "en")!

    @Test("EN→中文: English input translates to 中文 in one call (no flip)")
    func englishInputTranslatesToChinese() async throws {
        let coordinator = makeCoordinator(notebook: nil)
        // Detection says English; the home target is 中文, so the guard must NOT
        // flip — one call, the 中文 translation stands.
        let engine = ScriptedEngine(
            detected: .identified(Self.english, confidence: nil),
            byTargetCode: ["zh-CN": "你好", "en": "WRONG"]
        )

        let result = try await coordinator.translateWithGuard("Hello", using: engine)

        #expect(result.translation == "你好")
        #expect(await engine.requestedTargetCodes == ["zh-CN"]) // exactly one call
    }

    @Test("中文→EN: Chinese input re-fires the guard and flips to English")
    func chineseInputFlipsToEnglish() async throws {
        let coordinator = makeCoordinator(notebook: nil)
        // Detection says Chinese == the home target (中文) → the guard fires and
        // re-translates to the secondary (English): the old two-language flip.
        let engine = ScriptedEngine(
            detected: .identified(Self.chinese, confidence: nil),
            byTargetCode: ["zh-CN": "WRONG", "en": "Hello"]
        )

        let result = try await coordinator.translateWithGuard("你好", using: engine)

        #expect(result.translation == "Hello")
        // Two calls: first to 中文 (collision), then re-fired to English.
        #expect(await engine.requestedTargetCodes == ["zh-CN", "en"])
    }
}

/// A scriptable engine that returns a fixed detected source and a translation
/// keyed by the request's target code, recording each target so the guard's
/// re-fire is observable. An `actor` to satisfy `Sendable`.
private actor ScriptedEngine: TranslationEngine {
    nonisolated let kind: EngineKind = .free
    private let detected: DetectedSource
    private let byTargetCode: [String: String]
    private(set) var requestedTargetCodes: [String] = []

    init(detected: DetectedSource, byTargetCode: [String: String]) {
        self.detected = detected
        self.byTargetCode = byTargetCode
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        requestedTargetCodes.append(request.to.code)
        return TranslationResult(
            translation: byTargetCode[request.to.code] ?? "?",
            detected: detected,
            servedBy: kind,
            viaGoogleFallback: false
        )
    }

    func summarize(_ items: [VocabItem]) async throws -> String { "" }
}
