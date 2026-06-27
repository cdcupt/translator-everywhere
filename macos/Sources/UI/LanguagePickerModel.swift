import Foundation

/// A concrete selection the searchable picker yields (DESIGN §9 / TECH §8.1).
enum LanguageChoice: Equatable {
    /// Auto-detect the source — only offered by the From picker.
    case auto
    /// A specific catalog language.
    case language(Language)
}

/// One visual row in the picker list. Section headers and the empty-state line
/// are non-selectable; `auto` and `language` rows are selectable.
enum PickerRow: Equatable {
    case header(String)
    case auto
    case language(Language)
    case empty(String)

    /// The choice this row yields when picked, or `nil` for non-selectable rows.
    var choice: LanguageChoice? {
        switch self {
        case .auto: return .auto
        case let .language(language): return .language(language)
        case .header, .empty: return nil
        }
    }

    /// True for rows the keyboard/mouse can land on (everything except headers
    /// and the empty-state line).
    var isSelectable: Bool { choice != nil }
}

/// The picker's pure view-model: filtering, the pinned "Recent & last-used"
/// section, and keyboard-selection logic — with no AppKit dependency so it is
/// unit-testable in isolation. `LanguagePickerController` is a thin AppKit shell
/// over this; the visual panel is validated later on the running app.
struct LanguagePickerModel {

    /// Which control the picker drives. The From picker pins an "Auto-detect" row
    /// at the very top; the To picker never offers Auto.
    enum Mode: Equatable { case from, to }

    static let recentHeader = "Recent & last-used"
    static let allHeader = "All languages"

    let mode: Mode
    /// Recent & last-used targets to pin at the top, most-recent first.
    let recent: [Language]

    /// The rows currently displayed for the active query.
    private(set) var rows: [PickerRow]
    /// Index into `rows` of the highlighted selectable row, or `nil` when nothing
    /// is selectable (no matches).
    private(set) var highlighted: Int?

    init(mode: Mode, recent: [Language], query: String = "") {
        self.mode = mode
        self.recent = recent
        let rows = Self.buildRows(mode: mode, recent: recent, query: query)
        self.rows = rows
        self.highlighted = rows.firstIndex { $0.isSelectable }
    }

    /// Re-filters for `query` and re-homes the highlight to the first selectable
    /// row (matching the mockup: typing always returns the selection to the top).
    mutating func setQuery(_ query: String) {
        rows = Self.buildRows(mode: mode, recent: recent, query: query)
        highlighted = rows.firstIndex { $0.isSelectable }
    }

    /// Moves the highlight `delta` selectable steps, wrapping around and skipping
    /// header/empty rows. No-op when nothing is selectable.
    mutating func moveHighlight(by delta: Int) {
        let selectable = rows.indices.filter { rows[$0].isSelectable }
        guard !selectable.isEmpty else { highlighted = nil; return }
        let current = highlighted.flatMap { selectable.firstIndex(of: $0) } ?? 0
        let count = selectable.count
        let next = ((current + delta) % count + count) % count
        highlighted = selectable[next]
    }

    /// Highlights `row` only if it is selectable (mouse hover / click).
    mutating func setHighlight(toRow row: Int) {
        guard rows.indices.contains(row), rows[row].isSelectable else { return }
        highlighted = row
    }

    /// The choice under the highlight (what ↩ picks), or `nil`.
    var highlightedChoice: LanguageChoice? {
        highlighted.flatMap { rows[$0].choice }
    }

    /// The choice for a row index (mouse click), or `nil` when not selectable.
    func choice(atRow row: Int) -> LanguageChoice? {
        guard rows.indices.contains(row) else { return nil }
        return rows[row].choice
    }

    // MARK: - Row building

    /// Builds the row list: an optional Auto-detect row (From only), a pinned
    /// "Recent & last-used" section (only recents that survive the filter, in
    /// recent order), then "All languages" (the remaining matches in the catalog's
    /// A–Z / search-rank order). An unmatched query collapses to one empty row.
    static func buildRows(mode: Mode, recent: [Language], query: String) -> [PickerRow] {
        let matches = LanguageCatalog.search(query)
        let matchCodes = Set(matches.map(\.code))
        var rows: [PickerRow] = []

        if mode == .from, autoMatches(query) {
            rows.append(.auto)
        }

        let recentMatches = recent.filter { matchCodes.contains($0.code) }
        if !recentMatches.isEmpty {
            rows.append(.header(recentHeader))
            rows.append(contentsOf: recentMatches.map { PickerRow.language($0) })
        }

        let recentCodes = Set(recentMatches.map(\.code))
        let rest = matches.filter { !recentCodes.contains($0.code) }
        if !rest.isEmpty {
            rows.append(.header(allHeader))
            rows.append(contentsOf: rest.map { PickerRow.language($0) })
        }

        if !rows.contains(where: { $0.isSelectable }) {
            return [.empty(query)]
        }
        return rows
    }

    /// The Auto-detect row shows on an empty query or when the typed text is a
    /// prefix of "auto"/"detect" (or a substring of "auto detect") — mockup parity.
    private static func autoMatches(_ query: String) -> Bool {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        if needle.isEmpty { return true }
        return "auto".hasPrefix(needle)
            || "detect".hasPrefix(needle)
            || "auto detect".contains(needle)
    }
}
