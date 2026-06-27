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
        let item = try store.add(source: "hello", translation: "你好", from: "auto", to: "zh-CN", engine: .free)
        let dirty = try store.dirtyRows()
        #expect(dirty.contains { $0.clientUUID == item.clientUUID })
    }

    @Test("clearDirty drains the queue for unchanged pushed rows")
    func clearDirtyDrains() throws {
        let store = try makeStore()
        let item = try store.add(source: "hi", translation: "嗨", from: "auto", to: "zh-CN", engine: .free)
        // Push snapshot == live updatedAt → row is unchanged → de-queue it.
        try store.clearDirty([item.clientUUID: item.updatedAt])
        #expect(try store.dirtyRows().isEmpty)
    }

    @Test("clearDirty keeps a row edited DURING the in-flight push (no lost update)")
    func clearDirtyKeepsMidFlightEdit() throws {
        let store = try makeStore()
        let item = try store.add(source: "hi", translation: "嗨", from: "auto", to: "zh-CN", engine: .free)

        // 1. Sync snapshots the dirty row and pushes it (capture that updatedAt).
        let pushedUpdatedAt = item.updatedAt

        // 2. The user edits the SAME row while the push is in flight: this bumps
        //    updatedAt and re-marks it dirty (mirrors a real edit/softDelete).
        item.translation = "嗨嗨"
        item.updatedAt = pushedUpdatedAt.addingTimeInterval(5)
        item.isDirty = true
        try store.context.save()

        // 3. The push completes and clears dirty using the SNAPSHOT value. The
        //    newer edit must survive: the row stays dirty so it re-pushes next
        //    cycle. (On the old unconditional clear this row was wrongly drained
        //    → the edit was lost from the queue.)
        try store.clearDirty([item.clientUUID: pushedUpdatedAt])

        let stillQueued = try store.dirtyRows().contains { $0.clientUUID == item.clientUUID }
        #expect(stillQueued)
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
        let item = try store.add(source: "orig", translation: "原", from: "auto", to: "zh-CN", engine: .free)
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
        let item = try store.add(source: "bye", translation: "再见", from: "auto", to: "zh-CN", engine: .free)
        let id = item.clientUUID
        let tomb = VocabRow(clientUUID: id, sourceText: "bye", translation: "再见",
                            srcLang: "auto", tgtLang: "zh-CN", engine: "free", tag: nil,
                            createdAt: item.createdAt, updatedAt: item.updatedAt.addingTimeInterval(5),
                            tombstoned: true)
        _ = try store.mergePulled(tomb)
        #expect(try store.all().contains { $0.clientUUID == id } == false)
    }
}
