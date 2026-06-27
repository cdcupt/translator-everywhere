import Foundation
import Testing
@testable import Translator_Everywhere

/// The searchable-picker view-model (slice 7): filtering, the pinned
/// "Recent & last-used" section, the From-only Auto-detect row, and the
/// keyboard-selection index logic. The visual popover is validated later on the
/// running app; this covers the pure logic the AppKit shell renders.
@Suite("LanguagePickerModel — filter, recent pinning, keyboard")
struct LanguagePickerModelTests {

    private let zh = LanguageCatalog.language(forCode: "zh-CN")!
    private let en = LanguageCatalog.language(forCode: "en")!
    private let ja = LanguageCatalog.language(forCode: "ja")!

    @Test("To mode lists All languages (A–Z) with no Auto row")
    func toModeHasNoAuto() {
        let model = LanguagePickerModel(mode: .to, recent: [])
        #expect(!model.rows.contains(.auto))
        #expect(model.rows.first == .header(LanguagePickerModel.allHeader))
        // The first selectable row is a language; the highlight homes onto it.
        #expect(model.highlightedChoice != nil)
        if case .auto = model.highlightedChoice { Issue.record("To mode must not offer Auto") }
    }

    @Test("From mode pins an Auto-detect row first on an empty query")
    func fromModePinsAuto() {
        let model = LanguagePickerModel(mode: .from, recent: [])
        #expect(model.rows.first == .auto)
        #expect(model.highlightedChoice == .auto)
    }

    @Test("Recent & last-used pins recents above All, deduped from the All section")
    func recentPinning() {
        let model = LanguagePickerModel(mode: .to, recent: [zh, en])
        #expect(model.rows.first == .header(LanguagePickerModel.recentHeader))
        #expect(model.rows[1] == .language(zh))
        #expect(model.rows[2] == .language(en))

        let allIndex = model.rows.firstIndex(of: .header(LanguagePickerModel.allHeader))!
        let allRows = Array(model.rows[(allIndex + 1)...])
        #expect(!allRows.contains(.language(zh)))
        #expect(!allRows.contains(.language(en)))
    }

    @Test("Filtering narrows to matches and drops non-matching recents")
    func filterDropsNonMatchingRecents() {
        var model = LanguagePickerModel(mode: .to, recent: [zh, en])
        model.setQuery("japan")
        #expect(!model.rows.contains(.header(LanguagePickerModel.recentHeader)))
        #expect(model.rows.contains(.language(ja)))
        #expect(!model.rows.contains(.language(zh)))
    }

    @Test("A recent that survives the filter still pins above All")
    func recentSurvivesFilter() {
        var model = LanguagePickerModel(mode: .to, recent: [ja])
        model.setQuery("japan")
        #expect(model.rows.first == .header(LanguagePickerModel.recentHeader))
        #expect(model.rows[1] == .language(ja))
    }

    @Test("No matches collapses to a single non-selectable empty row")
    func emptyResults() {
        var model = LanguagePickerModel(mode: .to, recent: [])
        model.setQuery("zzzzzzz")
        #expect(model.rows.count == 1)
        #expect(model.highlighted == nil)
        #expect(model.highlightedChoice == nil)
    }

    @Test("Arrow keys wrap over selectable rows and skip headers")
    func keyboardWraps() {
        var model = LanguagePickerModel(mode: .from, recent: [zh])
        // rows: .auto, header(Recent), .language(zh), header(All), languages…
        #expect(model.highlightedChoice == .auto)
        model.moveHighlight(by: 1) // skips the Recent header, lands on zh
        #expect(model.highlightedChoice == .language(zh))
        model.moveHighlight(by: -1) // back to Auto
        #expect(model.highlightedChoice == .auto)
        model.moveHighlight(by: -1) // wraps to the last selectable row
        #expect(model.highlightedChoice != nil)
        if case .auto = model.highlightedChoice {
            Issue.record("Wrapping up from Auto should land on a real language, not Auto")
        }
    }

    @Test("Setting the query re-homes the highlight to the first selectable row")
    func setQueryReHomesHighlight() {
        var model = LanguagePickerModel(mode: .from, recent: [])
        model.moveHighlight(by: 3)
        model.setQuery("chi") // Chinese (Simplified)/(Traditional)…
        #expect(model.highlighted == model.rows.firstIndex { $0.isSelectable })
    }

    @Test("Auto-detect row appears for a prefix of auto/detect, hidden otherwise")
    func autoRowFiltering() {
        var model = LanguagePickerModel(mode: .from, recent: [])
        model.setQuery("au")
        #expect(model.rows.contains(.auto))
        model.setQuery("detec")
        #expect(model.rows.contains(.auto))
        model.setQuery("spanish")
        #expect(!model.rows.contains(.auto))
    }

    @Test("choice(atRow:) yields nil for headers and the language for a language row")
    func choiceAtRow() {
        let model = LanguagePickerModel(mode: .to, recent: [zh])
        #expect(model.choice(atRow: 0) == nil)             // Recent header
        #expect(model.choice(atRow: 1) == .language(zh))   // pinned recent
        #expect(model.choice(atRow: 999) == nil)           // out of bounds
    }
}
