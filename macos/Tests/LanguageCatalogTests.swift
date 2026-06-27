import Foundation
import Testing
@testable import Translator_Everywhere

/// Catalog foundation (Slice 1): the generated `Language` set, code/googleCode
/// lookups, the he/iw + jv/jw divergence, AI-eligibility, and search.
@Suite("Language catalog — lookup, googleCode divergence, search")
struct LanguageCatalogTests {

    @Test("Catalog ships the full Google set with unique codes")
    func catalogPopulatedAndUnique() {
        #expect(LanguageCatalog.all.count >= 100)
        let codes = Set(LanguageCatalog.all.map(\.code))
        #expect(codes.count == LanguageCatalog.all.count) // every code unique
    }

    @Test("language(forCode:) returns the canonical record; unknown is nil")
    func lookupByCode() throws {
        let zh = try #require(LanguageCatalog.language(forCode: "zh-CN"))
        #expect(zh.englishName.contains("Chinese"))
        #expect(zh.googleCode == "zh-CN")
        #expect(zh.id == zh.code)
        #expect(LanguageCatalog.language(forCode: "not-a-code") == nil)
    }

    @Test("googleCode diverges from code for Hebrew (he→iw) and Javanese (jv→jw)")
    func googleCodeDivergence() throws {
        let he = try #require(LanguageCatalog.language(forCode: "he"))
        #expect(he.googleCode == "iw")
        let jv = try #require(LanguageCatalog.language(forCode: "jv"))
        #expect(jv.googleCode == "jw")

        // Reverse lookup maps Google's wire code back to the canonical language —
        // this is how a detected source (Google returns "iw"/"jw") is resolved.
        #expect(LanguageCatalog.language(forGoogleCode: "iw")?.code == "he")
        #expect(LanguageCatalog.language(forGoogleCode: "jw")?.code == "jv")
    }

    @Test("language(forGoogleCode:) resolves an already-canonical code too")
    func googleCodeFallsBackToCanonical() {
        #expect(LanguageCatalog.language(forGoogleCode: "zh-CN")?.code == "zh-CN")
        #expect(LanguageCatalog.language(forGoogleCode: "fr")?.code == "fr")
    }

    @Test("Every language is AI-eligible in v1 (aiName non-nil)")
    func everyLanguageIsAISupported() {
        #expect(LanguageCatalog.all.allSatisfy { $0.aiSupported })
        #expect(LanguageCatalog.all.allSatisfy { $0.aiName != nil })
    }

    @Test("search matches englishName / endonym / code / alias, case- & diacritic-insensitive")
    func searchMatches() {
        #expect(LanguageCatalog.search("span").contains { $0.code == "es" })     // englishName prefix
        #expect(LanguageCatalog.search("Español").contains { $0.code == "es" })  // endonym
        #expect(LanguageCatalog.search("espanol").contains { $0.code == "es" })  // diacritic-insensitive
        #expect(LanguageCatalog.search("FR").contains { $0.code == "fr" })       // code, case-insensitive
        #expect(LanguageCatalog.search("tagalog").contains { $0.code == "fil" }) // alias
    }

    @Test("search ranks an exact code/name match ahead of substring matches")
    func searchRanksExactFirst() throws {
        let results = LanguageCatalog.search("fr")
        let first = try #require(results.first)
        #expect(first.code == "fr") // exact code beats "Frisian", "Afrikaans", …
    }

    @Test("empty search returns the whole catalog")
    func searchEmptyReturnsAll() {
        #expect(LanguageCatalog.search("").count == LanguageCatalog.all.count)
    }
}
