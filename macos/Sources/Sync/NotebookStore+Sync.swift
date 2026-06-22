import Foundation
import SwiftData

/// Bridges the SwiftData-backed `NotebookStore` to the sync layer's value-typed
/// `VocabSyncStore` contract (TECH §8.5). All `ModelContext` work stays here on
/// the main actor; the SyncClient only ever sees `VocabRow` snapshots.
extension NotebookStore: VocabSyncStore {

    /// The push queue: every row with `isDirty == true`, tombstones included
    /// (a dirty tombstone is a delete that still needs to propagate).
    func dirtyRows() throws -> [VocabRow] {
        let descriptor = FetchDescriptor<VocabItem>(
            predicate: #Predicate { $0.isDirty }
        )
        return try context.fetch(descriptor).map(Self.row(from:))
    }

    func clearDirty(_ clientUUIDs: [UUID]) throws {
        let set = Set(clientUUIDs)
        let descriptor = FetchDescriptor<VocabItem>(predicate: #Predicate { $0.isDirty })
        for item in try context.fetch(descriptor) where set.contains(item.clientUUID) {
            item.isDirty = false
        }
        try context.save()
    }

    @discardableResult
    func mergePulled(_ row: VocabRow) throws -> Bool {
        let uuid = row.clientUUID
        let descriptor = FetchDescriptor<VocabItem>(
            predicate: #Predicate { $0.clientUUID == uuid }
        )
        let existing = try context.fetch(descriptor).first

        guard let existing else {
            // New row from the cloud — insert as-is, not dirty (server is source).
            let item = VocabItem(
                clientUUID: row.clientUUID,
                sourceText: row.sourceText,
                translation: row.translation,
                srcLang: row.srcLang,
                tgtLang: row.tgtLang,
                engine: row.engine,
                tag: row.tag,
                createdAt: row.createdAt,
                updatedAt: row.updatedAt,
                tombstoned: row.tombstoned,
                isDirty: false
            )
            context.insert(item)
            try context.save()
            return true
        }

        // Last-write-wins: only adopt the incoming row if it is strictly newer.
        guard row.updatedAt > existing.updatedAt else { return false }
        existing.sourceText = row.sourceText
        existing.translation = row.translation
        existing.srcLang = row.srcLang
        existing.tgtLang = row.tgtLang
        existing.engine = row.engine
        existing.tag = row.tag
        existing.updatedAt = row.updatedAt
        existing.tombstoned = row.tombstoned
        existing.isDirty = false
        try context.save()
        return true
    }

    /// Snapshot a `@Model` into a `Sendable` value row.
    static func row(from item: VocabItem) -> VocabRow {
        VocabRow(
            clientUUID: item.clientUUID,
            sourceText: item.sourceText,
            translation: item.translation,
            srcLang: item.srcLang,
            tgtLang: item.tgtLang,
            engine: item.engine,
            tag: item.tag,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            tombstoned: item.tombstoned
        )
    }
}
