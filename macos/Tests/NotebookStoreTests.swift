import Foundation
import Testing
@testable import Translator_Everywhere

/// Notebook persistence + export. Uses an in-memory SwiftData store so nothing
/// touches disk and each test is isolated.
@MainActor
@Suite("NotebookStore — persistence, search, soft-delete, export", .serialized)
struct NotebookStoreTests {

    private func makeStore() throws -> NotebookStore {
        try NotebookStore(inMemory: true)
    }

    @Test("add then all() returns the item newest-first")
    func addAndFetchNewestFirst() throws {
        let store = try makeStore()
        let first = try store.add(source: "hello", translation: "你好", from: "en", to: "zh-CN", engine: .free)
        // Force a distinct createdAt ordering.
        first.createdAt = Date(timeIntervalSince1970: 1_000)
        try store.context.save()
        let second = try store.add(source: "world", translation: "世界", from: "en", to: "zh-CN", engine: .ai)
        second.createdAt = Date(timeIntervalSince1970: 2_000)
        try store.context.save()

        let all = try store.all()
        #expect(all.count == 2)
        #expect(all.first?.sourceText == "world") // newest first
        #expect(all.last?.sourceText == "hello")
    }

    @Test("new rows are dirty and not tombstoned")
    func newRowFlags() throws {
        let store = try makeStore()
        let item = try store.add(source: "a", translation: "b", from: "en", to: "zh-CN", engine: .free)
        #expect(item.isDirty == true)
        #expect(item.tombstoned == false)
        #expect(item.engine == "free")
    }

    @Test("add threads the explicit from/to codes into srcLang/tgtLang")
    func addThreadsLanguageCodes() throws {
        let store = try makeStore()
        // The orchestrator's resolved codes are stored verbatim — no in-store
        // derivation (the interim Han heuristic is gone). A flipped Chinese→English
        // capture stores from "zh-CN", to "en".
        let item = try store.add(
            source: "你好", translation: "Hello", from: "zh-CN", to: "en", engine: .ai
        )
        #expect(item.srcLang == "zh-CN")
        #expect(item.tgtLang == "en")
    }

    @Test("search filters by source or translation, case-insensitive")
    func searchFilter() throws {
        let store = try makeStore()
        try store.add(source: "Train platform", translation: "月台", from: "en", to: "zh-CN", engine: .free)
        try store.add(source: "Exit", translation: "出口", from: "en", to: "zh-CN", engine: .free)

        #expect(try store.all(matching: "train").count == 1)
        #expect(try store.all(matching: "月台").count == 1)
        #expect(try store.all(matching: "出口").count == 1)
        #expect(try store.all(matching: "nope").isEmpty)
        #expect(try store.all(matching: "").count == 2)
    }

    @Test("softDelete sets tombstone + dirty, bumps updatedAt, hides from all()")
    func softDeleteHides() throws {
        let store = try makeStore()
        let item = try store.add(source: "gone", translation: "走了", from: "en", to: "zh-CN", engine: .free)
        let before = item.updatedAt

        try store.softDelete(item)

        #expect(item.tombstoned == true)
        #expect(item.isDirty == true)
        #expect(item.updatedAt >= before)
        #expect(try store.all().isEmpty)          // hidden from the UI
        #expect(try store.all(matching: "gone").isEmpty)
    }

    @Test("clientUUID is unique and stable across re-fetch")
    func clientUUIDUniqueAndStable() throws {
        let store = try makeStore()
        let a = try store.add(source: "x", translation: "y", from: "en", to: "zh-CN", engine: .free)
        let uuid = a.clientUUID

        let fetched = try store.all()
        #expect(fetched.count == 1)
        #expect(fetched.first?.clientUUID == uuid) // survives re-fetch

        // Distinct rows get distinct UUIDs.
        let b = try store.add(source: "p", translation: "q", from: "en", to: "zh-CN", engine: .free)
        #expect(a.clientUUID != b.clientUUID)
    }

    // MARK: - Export

    /// A fixed item set with escape hazards, in known order.
    private func sampleItems(_ store: NotebookStore) throws -> [VocabItem] {
        let one = VocabItem(
            clientUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sourceText: "hello, world",            // comma → CSV-quoted
            translation: "你好，世界",
            srcLang: "auto",
            tgtLang: "zh-CN",
            engine: "free",
            tag: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let two = VocabItem(
            clientUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            sourceText: "a | b",                   // pipe → Markdown-escaped
            translation: "quote \" here",          // quote → CSV-doubled
            srcLang: "auto",
            tgtLang: "en",
            engine: "ai",
            tag: "travel",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        store.context.insert(one)
        store.context.insert(two)
        try store.context.save()
        return [one, two]
    }

    @Test("CSV export has header, stable order, and RFC-4180 escaping")
    func csvExport() throws {
        let store = try makeStore()
        let items = try sampleItems(store)
        let csv = store.export(items: items, as: .csv)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines[0] == "source,translation,src_lang,tgt_lang,engine,tag,created_at")
        #expect(lines[1].hasPrefix("\"hello, world\",")) // comma field quoted
        #expect(lines[2].contains("\"quote \"\" here\"")) // quote doubled + wrapped
        #expect(lines[2].contains(",ai,travel,"))
    }

    @Test("Markdown export has table header and escapes pipes")
    func markdownExport() throws {
        let store = try makeStore()
        let items = try sampleItems(store)
        let md = store.export(items: items, as: .markdown)

        #expect(md.contains("| Source | Translation | Languages | Engine | Tag | Date |"))
        #expect(md.contains("| --- | --- | --- | --- | --- | --- |"))
        #expect(md.contains("a \\| b"))     // pipe escaped
        #expect(md.contains("FREE"))
        #expect(md.contains("AI"))
    }
}
