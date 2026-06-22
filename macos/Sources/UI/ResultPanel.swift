import AppKit

/// The translation result UI (TECH §8.1).
///
/// An `NSPanel` subclass that *can become key* — an `LSUIElement` agent app has
/// no main window, so the panel must be allowed to take focus explicitly (the
/// coordinator calls `NSApp.activate` first). For slice 2 it renders the OCR'd
/// text under a "Recognized text" title; the translation body lands in slice 3.
final class ResultPanel: NSObject, NSWindowDelegate {

    /// A borderless utility panel that is allowed to become key/main despite the
    /// app having no Dock presence.
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private var panel: KeyablePanel?

    /// Shows (or re-uses) the panel with a title and body text. Must be called on
    /// the main actor — it touches AppKit views.
    @MainActor
    func show(title: String, body: String) {
        let panel = panel ?? makePanel()
        self.panel = panel

        configureContent(of: panel, title: title, body: body)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Tears down the panel.
    @MainActor
    func close() {
        panel?.close()
        panel = nil
    }

    // MARK: - Construction

    @MainActor
    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Translator Everywhere"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        return panel
    }

    @MainActor
    private func configureContent(of panel: KeyablePanel, title: String, body: String) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let bodyText = NSTextView()
        bodyText.string = body
        bodyText.isEditable = false
        bodyText.isSelectable = true
        bodyText.drawsBackground = false
        bodyText.font = .systemFont(ofSize: 14)
        bodyText.textContainerInset = NSSize(width: 4, height: 4)

        let scroll = NSScrollView()
        scroll.documentView = bodyText
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        panel.contentView = content

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                          constant: -(stack.edgeInsets.left + stack.edgeInsets.right)),
        ])
    }
}
