import AppKit
import Testing
@testable import Translator_Everywhere

/// The searchable picker's AppKit shell (beta A4/A5). Seeds the controller's model
/// the way `present(...)` + typing would (no transient popover — that is validated
/// on-device) and asserts the table datasource/delegate output: that the rendered
/// rows reflect `LanguageCatalog.search(query)` and that the "Recent & last-used"
/// section is pinned above "All languages".
@MainActor
@Suite("LanguagePickerController — table reflects filter + recent pinning")
struct LanguagePickerControllerTests {

    private let zh = LanguageCatalog.language(forCode: "zh-CN")!
    private let en = LanguageCatalog.language(forCode: "en")!
    private let ja = LanguageCatalog.language(forCode: "ja")!

    /// Renders every row through the controller's real datasource/delegate and
    /// returns `(selectable, label)` per row. `label` is a language row's
    /// accessibility label or a header's text — enough to assert row contents and
    /// section order without reaching into private model state. The datasource
    /// methods ignore the passed table (they read the seeded model), so a throwaway
    /// `NSTableView` is fine.
    private func renderRows(_ c: LanguagePickerController) -> [(selectable: Bool, label: String)] {
        let table = NSTableView()
        return (0..<c.numberOfRows(in: table)).map { row in
            let selectable = c.tableView(table, shouldSelectRow: row)
            let view = c.tableView(table, viewFor: nil, row: row)
            let ax = view?.accessibilityLabel()
            let text = view?.subviews.compactMap { $0 as? NSTextField }.first?.stringValue
            let label = (ax?.isEmpty == false ? ax : nil) ?? text ?? ""
            return (selectable, label)
        }
    }

    // A4 — typing filters the rendered table to the search matches.
    @Test("Filtering to \"japan\" renders Japanese and drops Chinese")
    func filterRendersMatches() {
        let controller = LanguagePickerController()
        controller.seedForTesting(mode: .to, recent: [], query: "japan")
        let labels = renderRows(controller).map(\.label)
        #expect(labels.contains { $0.contains(ja.englishName) })
        #expect(!labels.contains { $0.contains(zh.englishName) })
    }

    // A5 — recents pin above "All languages", in recent order.
    @Test("Recent & last-used rows are pinned above All languages")
    func recentPinnedAboveAll() {
        let controller = LanguagePickerController()
        controller.seedForTesting(mode: .to, recent: [zh, en], query: "")
        let rows = renderRows(controller)

        // The first row is the non-selectable "Recent & last-used" header.
        #expect(rows.first?.selectable == false)
        #expect(rows.first?.label == LanguagePickerModel.recentHeader.uppercased())

        // The two pinned recents render next, in recent order, before the
        // "All languages" header.
        let allHeaderIndex = rows.firstIndex {
            !$0.selectable && $0.label == LanguagePickerModel.allHeader.uppercased()
        }!
        let pinned = rows[1..<allHeaderIndex].filter(\.selectable).map(\.label)
        #expect(pinned.count == 2)
        #expect(pinned[0].contains(zh.englishName))
        #expect(pinned[1].contains(en.englishName))
    }

    // A4 — the From picker keeps an Auto-detect row at the very top.
    @Test("From mode renders a selectable Auto-detect row first")
    func fromModeAutoRow() {
        let controller = LanguagePickerController()
        controller.seedForTesting(mode: .from, recent: [], query: "")
        let rows = renderRows(controller)
        #expect(rows.first?.selectable == true)
        #expect(rows.first?.label.contains("Auto-detect") == true)
    }
}
