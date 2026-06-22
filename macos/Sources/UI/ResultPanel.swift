import AppKit

/// The translation result UI (TECH §8.1).
///
/// An `NSPanel` subclass that *can become key* — an `LSUIElement` agent app has
/// no main window, so the panel must be allowed to take focus explicitly (the
/// coordinator calls `NSApp.activate` first). Slice 3 renders a translation
/// result: the translation large/primary, the recognized source dim/smaller, an
/// engine badge (FREE/AI), and a "Copied ✓" affordance once the translation is
/// on the pasteboard. Errors render as a distinct error state.
final class ResultPanel: NSObject, NSWindowDelegate {

    /// A borderless utility panel that is allowed to become key/main despite the
    /// app having no Dock presence.
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private var panel: KeyablePanel?

    /// Shows a successful translation: `translation` is primary/large, `source`
    /// is the dim recognized text, `badge` labels the engine, and `copied`
    /// reveals the "Copied ✓" affordance. Must be called on the main actor.
    @MainActor
    func showResult(translation: String, source: String, badge: String, copied: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = makeResultContent(
            translation: translation, source: source, badge: badge, copied: copied
        )
        present(panel)
    }

    /// Shows an error state — a title and message, no copy affordance.
    @MainActor
    func showError(title: String, message: String) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = makeMessageContent(title: title, body: message, isError: true)
        present(panel)
    }

    /// Back-compat informational message (permission/no-text/etc.).
    @MainActor
    func show(title: String, body: String) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = makeMessageContent(title: title, body: body, isError: false)
        present(panel)
    }

    /// Tears down the panel.
    @MainActor
    func close() {
        panel?.close()
        panel = nil
    }

    // MARK: - Presentation

    @MainActor
    private func present(_ panel: KeyablePanel) {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Construction

    @MainActor
    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
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

    /// Result layout: badge + "Copied ✓" header row, large translation, dim
    /// source underneath.
    @MainActor
    private func makeResultContent(
        translation: String, source: String, badge: String, copied: Bool
    ) -> NSView {
        let header = NSStackView(views: [badgeView(badge)])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        if copied {
            header.addArrangedSubview(copiedLabel())
        }
        header.addArrangedSubview(spacer())

        let translationView = scrollableText(translation, fontSize: 18, dim: false)

        let sourceLabel = NSTextField(labelWithString: "Source")
        sourceLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        sourceLabel.textColor = .tertiaryLabelColor

        let sourceView = scrollableText(source, fontSize: 12, dim: true)

        let stack = verticalStack([header, translationView, sourceLabel, sourceView])
        stack.setCustomSpacing(12, after: translationView)
        return wrap(stack, mainView: translationView)
    }

    /// Title + body layout for info/error states.
    @MainActor
    private func makeMessageContent(title: String, body: String, isError: Bool) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = isError ? .systemRed : .secondaryLabelColor

        let bodyView = scrollableText(body, fontSize: 14, dim: false)

        let stack = verticalStack([titleLabel, bodyView])
        return wrap(stack, mainView: bodyView)
    }

    // MARK: - View helpers

    @MainActor
    private func badgeView(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 4
        container.layer?.backgroundColor = (text == "AI"
            ? NSColor.systemPurple : NSColor.systemBlue).cgColor
        container.addSubview(label)
        container.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
        ])
        return container
    }

    @MainActor
    private func copiedLabel() -> NSView {
        let label = NSTextField(labelWithString: "Copied ✓")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .systemGreen
        return label
    }

    @MainActor
    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    @MainActor
    private func scrollableText(_ string: String, fontSize: CGFloat, dim: Bool) -> NSScrollView {
        let textView = NSTextView()
        textView.string = string
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = dim ? .secondaryLabelColor : .labelColor
        textView.textContainerInset = NSSize(width: 2, height: 2)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    @MainActor
    private func verticalStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// Pins a stack to fill the content view and makes `mainView` stretch full
    /// width so wrapped text uses the panel width.
    @MainActor
    private func wrap(_ stack: NSStackView, mainView: NSView) -> NSView {
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainView.widthAnchor.constraint(
                equalTo: stack.widthAnchor,
                constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
            ),
        ])
        return content
    }
}
