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
}
