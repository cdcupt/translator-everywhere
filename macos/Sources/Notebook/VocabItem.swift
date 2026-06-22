import Foundation
import SwiftData

/// The local notebook row (TECH §8.3).
///
/// A SwiftData `@Model` that mirrors the server `vocab_items` row 1:1 (§2), plus
/// the small client-only bookkeeping sync needs: a stable `clientUUID` (the join
/// key — `@Attribute(.unique)`, generated once at creation so it survives
/// restarts and Macs), a `isDeleted` tombstone so deletes propagate instead of
/// resurrecting, and a `isDirty` push flag (the offline change queue *is* the
/// store: "the queue" is simply `isDirty == true`).
///
/// Sync (slice 7) reads these flags; this slice only sets them correctly and
/// never pushes. The notebook is fully functional with this store alone — no
/// account, no network.
@Model
final class VocabItem: Identifiable {

    /// `Table`/selection identity — the stable `clientUUID`, not the
    /// `PersistentIdentifier`, so selection survives re-fetches and filtering.
    var id: UUID { clientUUID }

    /// The stable sync join key. Generated on-device at creation and unique
    /// across the store; a re-pushed row updates rather than duplicates.
    @Attribute(.unique) var clientUUID: UUID

    /// The recognized / entered source text.
    var sourceText: String

    /// The translation produced by the active engine.
    var translation: String

    /// BCP-47-ish source language tag (e.g. "auto", "en", "zh").
    var srcLang: String

    /// BCP-47-ish target language tag (e.g. "en", "zh-CN").
    var tgtLang: String

    /// Which engine produced this row — stores `EngineKind.rawValue`
    /// ("free" | "ai"). Drives the FREE/AI badge in the notebook table.
    var engine: String

    /// Optional user-assigned tag for grouping.
    var tag: String?

    /// When the row was first created.
    var createdAt: Date

    /// Last-write-wins clock — bumped on every local mutation (incl. delete).
    var updatedAt: Date

    /// Tombstone (server `deleted` column). A soft delete sets this `true` +
    /// bumps `updatedAt` so the delete can sync; `all(matching:)` excludes
    /// tombstoned rows from the UI.
    ///
    /// NOTE: named `tombstoned`, not `isDeleted`, on purpose — SwiftData is
    /// Core Data-backed and `isDeleted` collides with `NSManagedObject.isDeleted`
    /// (which reports context-deletion, not our soft-delete flag), so a stored
    /// `isDeleted` attribute is silently shadowed by the getter.
    var tombstoned: Bool

    /// Needs-push flag (the offline change queue). Defaults `true` on creation
    /// and any mutation; slice-7 sync clears it after a successful push.
    var isDirty: Bool

    init(
        clientUUID: UUID = UUID(),
        sourceText: String,
        translation: String,
        srcLang: String,
        tgtLang: String,
        engine: String,
        tag: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        tombstoned: Bool = false,
        isDirty: Bool = true
    ) {
        self.clientUUID = clientUUID
        self.sourceText = sourceText
        self.translation = translation
        self.srcLang = srcLang
        self.tgtLang = tgtLang
        self.engine = engine
        self.tag = tag
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tombstoned = tombstoned
        self.isDirty = isDirty
    }

    /// The engine kind for badge rendering; falls back to `.free` for any
    /// unrecognized stored value.
    var engineKind: EngineKind {
        EngineKind(rawValue: engine) ?? .free
    }
}
