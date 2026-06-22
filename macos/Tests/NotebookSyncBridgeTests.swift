import Foundation
import Testing
@testable import Translator_Everywhere

/// Exercises the real SwiftData-backed `VocabSyncStore` conformance (the merge +
/// dirty-queue plumbing the SyncClient drives in production).
@MainActor
@Suite("NotebookStore+Sync — dirty queue + last-write-wins merge")
struct NotebookSyncBridgeTests {

    private func makeStore() throws -> NotebookStore {
        try NotebookStore(inMemory: true)
    }

    @Test("a freshly added row appears in the dirty queue")
    func addedRowIsDirty() throws {
        let store = try makeStore()
        let item = try store.add(source: "hello", translation: "你好", engine: .free)
        let dirty = try store.dirtyRows()
        #expect(dirty.contains { $0.clientUUID == item.clientUUID })
    }

    @Test("clearDirty drains the queue for the given UUIDs")
    func clearDirtyDrains() throws {
        let store = try makeStore()
        let item = try store.add(source: "hi", translation: "嗨", engine: .free)
        try store.clearDirty([item.clientUUID])
        #expect(try store.dirtyRows().isEmpty)
    }

    @Test("mergePulled inserts a brand-new cloud row (not dirty)")
    func mergeInsertsNew() throws {
        let store = try makeStore()
        let row = VocabRow(
            clientUUID: UUID(), sourceText: "cloud", translation: "云",
            srcLang: "auto", tgtLang: "zh-CN", engine: "free", tag: nil,
            createdAt: Date(), updatedAt: Date(), tombstoned: false
        )
        #expect(try store.mergePulled(row) == true)
        // Inserted from the cloud → must NOT be dirty (no echo back).
        #expect(try store.dirtyRows().isEmpty)
        #expect(try store.all().contains { $0.sourceText == "cloud" })
    }

    @Test("mergePulled adopts a strictly-newer remote row, ignores older")
    func mergeLastWriteWins() throws {
        let store = try makeStore()
        let item = try store.add(source: "orig", translation: "原", engine: .free)
        let id = item.clientUUID
        let base = item.updatedAt

        // Older remote → ignored.
        let older = VocabRow(clientUUID: id, sourceText: "orig", translation: "OLD",
                             srcLang: "auto", tgtLang: "zh-CN", engine: "free", tag: nil,
                             createdAt: base, updatedAt: base.addingTimeInterval(-10), tombstoned: false)
        #expect(try store.mergePulled(older) == false)

        // Newer remote → adopted.
        let newer = VocabRow(clientUUID: id, sourceText: "orig", translation: "NEW",
                             srcLang: "auto", tgtLang: "zh-CN", engine: "free", tag: nil,
                             createdAt: base, updatedAt: base.addingTimeInterval(10), tombstoned: false)
        #expect(try store.mergePulled(newer) == true)
        #expect(try store.all().first { $0.clientUUID == id }?.translation == "NEW")
    }

    @Test("a pulled tombstone hides the row from the notebook")
    func mergeTombstoneHides() throws {
        let store = try makeStore()
        let item = try store.add(source: "bye", translation: "再见", engine: .free)
        let id = item.clientUUID
        let tomb = VocabRow(clientUUID: id, sourceText: "bye", translation: "再见",
                            srcLang: "auto", tgtLang: "zh-CN", engine: "free", tag: nil,
                            createdAt: item.createdAt, updatedAt: item.updatedAt.addingTimeInterval(5),
                            tombstoned: true)
        _ = try store.mergePulled(tomb)
        #expect(try store.all().contains { $0.clientUUID == id } == false)
    }
}
