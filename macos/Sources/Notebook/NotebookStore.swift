import Foundation
import SwiftData

/// The local notebook + offline change queue (TECH §8.3).
///
/// A thin wrapper over a SwiftData `ModelContainer`/`ModelContext` — the single
/// source of truth the UI binds to. The app is fully usable with no account and
/// no network; the `isDirty` flag is the push queue slice-7 sync will drain.
///
/// `@MainActor` because the bound `ModelContext` and the SwiftUI table that
/// reads it live on the main actor. Tests use the in-memory initializer so they
/// never touch the on-disk store.
@MainActor
final class NotebookStore {

    /// Export formats for `export(items:as:)`.
    enum ExportFormat {
        case csv
        case markdown
    }

    /// The on-disk store location under Application Support.
    static let storeFileName = "Notebook.store"

    let container: ModelContainer

    /// Convenience accessor for the container's main context.
    var context: ModelContext { container.mainContext }

    /// Production initializer — a persistent store under Application Support.
    /// Throwing so the caller can decide how to surface a catastrophic store
    /// failure; in practice this only fails on a corrupt/locked store.
    init() throws {
        let schema = Schema([VocabItem.self])
        let url = try Self.storeURL()
        let configuration = ModelConfiguration(schema: schema, url: url)
        self.container = try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Test / in-memory initializer — nothing is written to disk.
    ///
    /// Each container gets a **unique configuration name** so multiple in-memory
    /// stores in one process don't alias the same backing — without it, creating
    /// a second in-memory container resets the first's context and invalidates
    /// its `@Model` instances (SwiftData quirk).
    init(inMemory: Bool) throws {
        let schema = Schema([VocabItem.self])
        let configuration = ModelConfiguration(
            "notebook-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        self.container = container
        // Keep the in-memory container alive for the whole process. When a test
        // store goes out of scope its container would otherwise dealloc and call
        // `ModelContext.reset`, poisoning any `@Model` instance still referenced
        // (e.g. by Swift Testing's parallel worker) → a teardown crash. Pinning
        // the container avoids that; it's test-only memory, freed at exit.
        if inMemory {
            Self.pinnedContainers.append(container)
        }
    }

    /// Process-lifetime strong refs to in-memory containers (test isolation).
    nonisolated(unsafe) private static var pinnedContainers: [ModelContainer] = []

    // MARK: - Mutations

    /// Inserts a new capture. Generates a fresh `clientUUID`, derives the
    /// language pair from the source text, and marks the row dirty so a future
    /// sync pushes it. Returns the inserted item.
    @discardableResult
    func add(source: String, translation: String, engine: EngineKind) throws -> VocabItem {
        let target = LanguageDirection.target(for: source)
        let now = Date()
        let item = VocabItem(
            sourceText: source,
            translation: translation,
            srcLang: "auto",
            tgtLang: target.googleCode,
            engine: engine.rawValue,
            createdAt: now,
            updatedAt: now,
            tombstoned: false,
            isDirty: true
        )
        context.insert(item)
        try context.save()
        return item
    }

    /// Soft-deletes an item: sets the tombstone, bumps `updatedAt`, and marks it
    /// dirty so the delete propagates on the next sync. The row is *not* hard
    /// removed — that would resurrect on pull.
    func softDelete(_ item: VocabItem) throws {
        item.tombstoned = true
        item.updatedAt = Date()
        item.isDirty = true
        try context.save()
    }

    // MARK: - Queries

    /// All visible items, newest first, excluding tombstoned rows. When
    /// `searchText` is non-empty, filters to rows whose source or translation
    /// contains it (case-insensitive).
    func all(matching searchText: String = "") throws -> [VocabItem] {
        let descriptor = FetchDescriptor<VocabItem>(
            predicate: #Predicate { !$0.tombstoned },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let items = try context.fetch(descriptor)

        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }

        // Filter in-memory: `#Predicate` can't capture `localizedCaseInsensitive`
        // helpers reliably across the SwiftData/Foundation boundary, and the
        // notebook is small enough that an in-memory contains is fine.
        let lowered = needle.lowercased()
        return items.filter {
            $0.sourceText.lowercased().contains(lowered)
                || $0.translation.lowercased().contains(lowered)
        }
    }

    // MARK: - Export

    /// Renders `items` to a CSV or Markdown string. Stable column order; CSV
    /// fields are RFC-4180 escaped. Newest-first is the caller's responsibility
    /// (pass the result of `all`).
    func export(items: [VocabItem], as format: ExportFormat) -> String {
        switch format {
        case .csv:
            return Self.csv(items)
        case .markdown:
            return Self.markdown(items)
        }
    }

    private static let csvHeader = "source,translation,src_lang,tgt_lang,engine,tag,created_at"

    private static func csv(_ items: [VocabItem]) -> String {
        var rows = [csvHeader]
        let formatter = ISO8601DateFormatter()
        for item in items {
            let fields = [
                item.sourceText,
                item.translation,
                item.srcLang,
                item.tgtLang,
                item.engine,
                item.tag ?? "",
                formatter.string(from: item.createdAt),
            ]
            rows.append(fields.map(csvEscape).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    /// RFC-4180: wrap in quotes if the field contains a comma, quote, or
    /// newline; double any embedded quotes.
    private static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func markdown(_ items: [VocabItem]) -> String {
        var lines = [
            "# Vocabulary Notebook",
            "",
            "| Source | Translation | Languages | Engine | Tag | Date |",
            "| --- | --- | --- | --- | --- | --- |",
        ]
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        for item in items {
            let langs = "\(item.srcLang) → \(item.tgtLang)"
            let cells = [
                mdEscape(item.sourceText),
                mdEscape(item.translation),
                langs,
                item.engineKind.badge,
                mdEscape(item.tag ?? ""),
                formatter.string(from: item.createdAt),
            ]
            lines.append("| \(cells.joined(separator: " | ")) |")
        }
        return lines.joined(separator: "\n")
    }

    /// Escape Markdown table cell hazards: pipes and newlines break the table.
    private static func mdEscape(_ field: String) -> String {
        field
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Store location

    private static func storeURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("Translator Everywhere", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(storeFileName)
    }
}
