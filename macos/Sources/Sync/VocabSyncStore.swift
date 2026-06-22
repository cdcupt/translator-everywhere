import Foundation

/// A plain value snapshot of a vocab row crossing the sync boundary. SwiftData
/// `@Model` instances aren't `Sendable`, so the store hands the SyncClient these
/// value rows (and takes them back) — keeping all `ModelContext` work on the
/// main actor inside the store.
struct VocabRow: Sendable, Equatable {
    var clientUUID: UUID
    var sourceText: String
    var translation: String
    var srcLang: String
    var tgtLang: String
    var engine: String
    var tag: String?
    var createdAt: Date
    var updatedAt: Date
    var tombstoned: Bool
}

/// The store operations the SyncClient needs, abstracted so it can be unit
/// tested against an in-memory fake without a real `ModelContainer`.
///
/// `@MainActor` because the real implementation is `NotebookStore` (its
/// `ModelContext` is main-actor); the SyncClient `await`s across the hop.
@MainActor
protocol VocabSyncStore: AnyObject {

    /// All rows where `isDirty == true` (the push queue), tombstones included.
    func dirtyRows() throws -> [VocabRow]

    /// Clears `isDirty` after a successful push, but only for rows that have NOT
    /// changed since they were snapshotted into the push. `pushed` maps each
    /// pushed `clientUUID` to the `updatedAt` that was actually sent. A row is
    /// de-queued only when its live `updatedAt` still equals the pushed value;
    /// if the user edited it mid-flight (newer `updatedAt`), it stays dirty so
    /// the newer edit re-pushes next cycle (no lost update).
    func clearDirty(_ pushed: [UUID: Date]) throws

    /// Applies a pulled row by last-write-wins on `updatedAt`, keyed by
    /// `clientUUID`: insert if new, overwrite (incl. tombstone) only when the
    /// incoming `updatedAt` is strictly newer. Merged rows are NOT marked dirty
    /// (they came from the server). Returns whether anything changed.
    @discardableResult
    func mergePulled(_ row: VocabRow) throws -> Bool
}
