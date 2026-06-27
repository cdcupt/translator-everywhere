import AppKit

/// The searchable language picker: an `NSPopover` hosting an auto-focused
/// `NSSearchField` over an `NSTableView` (DESIGN §9, mockup). All filtering,
/// recent-pinning, and keyboard-selection logic lives in `LanguagePickerModel`;
/// this is the AppKit shell that renders the model's `rows`/`highlighted` and
/// reports the chosen `LanguageChoice`.
///
/// Keyboard model (the search field stays first responder throughout):
/// type-to-filter, ↑/↓ move the highlight over selectable rows (wrapping, headers
/// skipped), ↩ picks the highlight, esc closes. A click picks a row directly.
@MainActor
final class LanguagePickerController: NSObject {

    private let popover = NSPopover()
    private let searchField = NSSearchField()
    private let tableView = NSTableView()

    private var model = LanguagePickerModel(mode: .to, recent: [])
    private var onChoose: ((LanguageChoice) -> Void)?

    private enum RowHeight {
        static let header: CGFloat = 24
        static let auto: CGFloat = 38
        static let language: CGFloat = 32
        static let empty: CGFloat = 46
    }

    override init() {
        super.init()
        buildPopover()
    }

    /// Opens the picker anchored under `source`, seeded for `mode` + `recent`,
    /// reporting the pick via `onChoose`. The search field becomes first responder
    /// so the user can type immediately.
    func present(
        from source: NSView,
        mode: LanguagePickerModel.Mode,
        recent: [Language],
        onChoose: @escaping (LanguageChoice) -> Void
    ) {
        self.onChoose = onChoose
        model = LanguagePickerModel(mode: mode, recent: recent)
        searchField.stringValue = ""
        applyHighlight()
        popover.show(relativeTo: source.bounds, of: source, preferredEdge: .maxY)
        // Focus the search field once the popover's window exists.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.popover.contentViewController?.view.window?.makeFirstResponder(self.searchField)
        }
    }

    // MARK: - Construction

    private func buildPopover() {
        searchField.placeholderString = "Search languages…"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.focusRingType = .default
        searchField.setAccessibilityLabel("Search languages")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.rowSizeStyle = .custom
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsEmptySelection = true
        tableView.refusesFirstResponder = true

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(searchField)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 300),
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -9),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            scroll.heightAnchor.constraint(equalToConstant: 250),
        ])

        let viewController = NSViewController()
        viewController.view = container
        popover.contentViewController = viewController
        popover.behavior = .transient
    }

    // MARK: - Test seam

    /// Seeds the picker's model exactly as `present(...)` + typing would (mode +
    /// recents + query) **without** showing the transient popover, so the table's
    /// datasource/delegate output can be asserted headlessly. The visual popover
    /// is validated on-device.
    func seedForTesting(mode: LanguagePickerModel.Mode, recent: [Language], query: String = "") {
        model = LanguagePickerModel(mode: mode, recent: recent)
        model.setQuery(query)
    }

    // MARK: - Selection

    private func applyHighlight() {
        tableView.reloadData()
        if let highlighted = model.highlighted {
            tableView.scrollRowToVisible(highlighted)
        }
    }

    private func choose(_ choice: LanguageChoice) {
        let handler = onChoose
        popover.performClose(nil)
        handler?(choice)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, let choice = model.choice(atRow: row) else { return }
        choose(choice)
    }
}

// MARK: - Search field keyboard model

extension LanguagePickerController: NSSearchFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        model.setQuery(searchField.stringValue)
        applyHighlight()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            model.moveHighlight(by: 1)
            applyHighlight()
            return true
        case #selector(NSResponder.moveUp(_:)):
            model.moveHighlight(by: -1)
            applyHighlight()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let choice = model.highlightedChoice { choose(choice) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            popover.performClose(nil)
            return true
        default:
            return false
        }
    }
}

// MARK: - Table data + rows

extension LanguagePickerController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch model.rows[row] {
        case .header: return RowHeight.header
        case .auto: return RowHeight.auto
        case .language: return RowHeight.language
        case .empty: return RowHeight.empty
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        model.rows[row].isSelectable
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        makeRowView(model.rows[row], highlighted: row == model.highlighted)
    }

    private func makeRowView(_ row: PickerRow, highlighted: Bool) -> NSView {
        switch row {
        case let .header(title):
            return headerRow(title)
        case .auto:
            return languageRow(
                primary: "Auto-detect", secondary: "detect source", code: "",
                accent: true, highlighted: highlighted,
                accessibility: "Auto-detect the source language"
            )
        case let .language(language):
            return languageRow(
                primary: language.endonym, secondary: language.englishName,
                code: language.code, accent: false, highlighted: highlighted,
                accessibility: "\(language.endonym), \(language.englishName), code \(language.code)"
            )
        case let .empty(query):
            return emptyRow(query)
        }
    }

    private func headerRow(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 9.5, weight: .bold)
        label.textColor = .controlAccentColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
        ])
        container.setAccessibilityElement(false)
        return container
    }

    private func languageRow(
        primary: String, secondary: String, code: String,
        accent: Bool, highlighted: Bool, accessibility: String
    ) -> NSView {
        let name = NSTextField(labelWithString: primary)
        name.font = .systemFont(ofSize: 13, weight: accent ? .semibold : .regular)
        name.textColor = accent ? .controlAccentColor : .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let english = NSTextField(labelWithString: secondary)
        english.font = .systemFont(ofSize: 11.5)
        english.textColor = .secondaryLabelColor
        english.lineBreakMode = .byTruncatingTail

        let codeLabel = NSTextField(labelWithString: code)
        codeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        codeLabel.textColor = .tertiaryLabelColor
        codeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: code.isEmpty ? [name, english] : [name, english, codeLabel])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        stack.distribution = .fill

        let row = highlightContainer(highlighted: highlighted)
        row.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -9),
            stack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.button)
        row.setAccessibilityLabel(accessibility)
        return row
    }

    private func emptyRow(_ query: String) -> NSView {
        let label = NSTextField(labelWithString: "No language matches “\(query)”")
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 9),
        ])
        return container
    }

    /// A row background that paints the accent tint when highlighted, so the
    /// keyboard/hover selection is visible even though the table is not first
    /// responder.
    private func highlightContainer(highlighted: Bool) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 7
        view.layer?.backgroundColor = highlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
        return view
    }
}
