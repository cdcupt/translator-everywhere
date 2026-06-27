import AppKit

/// The result-presentation surface `CaptureCoordinator` depends on — the seam
/// (mirroring `Translating`) that lets the present path be unit-tested with a spy:
/// which `LanguagePair` the bar is handed, the threaded save codes, etc.
/// `ResultPanel` is the production conformer.
@MainActor
protocol ResultPresenting: AnyObject {
    func showResult(
        translation: String,
        source: String,
        badge: String,
        copied: Bool,
        pair: LanguagePair?,
        detected: DetectedSource,
        viaGoogleFallback: Bool,
        onSave: (@MainActor () async -> Bool)?,
        onRetranslate: (@MainActor (LanguagePair) -> Void)?
    )
    /// Shows the panel *immediately* in a loading state the moment a region is
    /// captured, before OCR/translation run — so the user sees the app working
    /// instead of dead air. `source` is the recognized text once OCR lands (`nil`
    /// on the first call, right after capture). The real result later supersedes
    /// this in place via `showResult`.
    func showTranslating(source: String?)
    func showError(title: String, message: String)
    func show(title: String, body: String)
}

/// The translation result UI (TECH §8.1).
///
/// An `NSPanel` subclass that *can become key* — an `LSUIElement` agent app has
/// no main window, so the panel must be allowed to take focus explicitly (the
/// coordinator calls `NSApp.activate` first). Slice 3 renders a translation
/// result: the translation large/primary, the recognized source dim/smaller, an
/// engine badge (FREE/AI), and a "Copied ✓" affordance once the translation is
/// on the pasteboard. Errors render as a distinct error state.
final class ResultPanel: NSObject, NSWindowDelegate, ResultPresenting {

    /// A borderless utility panel that is allowed to become key/main despite the
    /// app having no Dock presence.
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    /// Layout constants shared across the result presentation.
    private enum Layout {
        /// Minimum height each result scroll view (Translation, Recognized) keeps
        /// so neither section can be squeezed to near-zero height — the user must
        /// always be able to read both to compare them.
        static let minSectionHeight: CGFloat = 56
    }

    private var panel: KeyablePanel?

    /// Non-secret preferences — injected so the panel shares the coordinator's
    /// single `SettingsStore` instead of allocating a fresh one per default-pair
    /// fallback / picker open (so Recent reflects reality and the panel stays
    /// testable). Defaults to a real store for older call sites / tests.
    private let settings: SettingsStore

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        super.init()
    }

    /// Strong reference to the current result's Save-button controller, if any.
    /// An `NSButton.target` is non-owning, so without this the controller would
    /// dealloc as soon as `saveControl` returns and the button's target would
    /// dangle. Held for the lifetime of the shown result; replaced (and the old
    /// one released) the next time a result or message is presented.
    private var saveButtonController: SaveButtonController?

    /// Strong reference to the live result's language-bar controller (From/To bar
    /// + searchable picker). Held like `saveButtonController` because the bar's
    /// `NSButton` targets are non-owning; replaced (and the old one released) the
    /// next time a *fresh* result body is built, and dropped on a message/error.
    private var languageBarController: LanguageBarController?

    /// References into the live result body, used to update it in place on a
    /// retranslate instead of rebuilding the whole panel (the bar — and any open
    /// picker — survives). Weak: the view hierarchy owns them, so swapping in a
    /// message/error content view auto-nils these.
    private weak var translationTextView: NSTextView?
    private weak var sourceTextView: NSTextView?
    private weak var headerStack: NSStackView?

    /// The current result's retranslate hook, captured so the bar's pick handler
    /// can fire it after showing in-place "translating…" feedback.
    private var currentOnRetranslate: (@MainActor (LanguagePair) -> Void)?

    /// True while the instant loading body (spinner + "Translating…") is mounted,
    /// from the moment a region is captured until the result/error supersedes it.
    /// Distinguishes "loading body up" from "result body up" so `showResult` knows
    /// to rebuild the result body in place (filling the loading state) rather than
    /// taking the retranslate in-place `updateResult` path.
    private var isShowingLoading = false

    /// The loading body's indeterminate spinner, held so it can be stopped when the
    /// result/error lands. Weak: the view hierarchy owns it.
    private weak var loadingSpinner: NSProgressIndicator?

    /// The loading body's Recognized text view, held so the recognized text can be
    /// filled *in place* (no rebuild) when OCR completes while still "Translating…".
    private weak var loadingSourceTextView: NSTextView?

    /// Shows a successful translation: `translation` is primary/large, `source`
    /// is the dim recognized text, `badge` labels the engine, and `copied`
    /// reveals the "Copied ✓" affordance. When `onSave` is non-nil a "Save to
    /// Notebook" button (⌘S) is offered; clicking it awaits the handler and, on
    /// success, swaps to a confirmed "★ Saved" state so the user can't
    /// double-save. Must be called on the main actor.
    ///
    /// Renders the multi-language From/To language bar (slice 7) from `pair` +
    /// `detected`, with a faint "via Google" note when an AI-preferred pair was
    /// routed to Google. When the panel already shows a result (a retranslate),
    /// the body is updated *in place* via `updateResult` so the bar/picker and the
    /// scroll views are not torn down; otherwise a fresh result body is built.
    @MainActor
    func showResult(
        translation: String,
        source: String,
        badge: String,
        copied: Bool,
        pair: LanguagePair? = nil,
        detected: DetectedSource = .unavailable,
        viaGoogleFallback: Bool = false,
        onSave: (@MainActor () async -> Bool)? = nil,
        onRetranslate: (@MainActor (LanguagePair) -> Void)? = nil
    ) {
        // Auto-detect (`from: nil`) to the home target is the safe default when a
        // caller omits the pair (older call sites / tests).
        let pair = pair ?? LanguagePair(from: nil, to: settings.homeTarget)

        let panel = panel ?? makePanel()
        self.panel = panel

        // A live result body → update in place (keep the bar + picker + scrollers).
        // Not while loading: the loading body has no bar to update, so it must be
        // rebuilt into a full result body below.
        if translationTextView != nil, !isShowingLoading {
            updateResult(
                translation: translation, source: source, badge: badge, copied: copied,
                pair: pair, detected: detected, viaGoogleFallback: viaGoogleFallback,
                onSave: onSave, onRetranslate: onRetranslate
            )
            present(panel, recenter: false)
            return
        }

        // Build the full result body. When a loading body is already up, keep the
        // panel exactly where it is (no recenter) and stop the spinner — the result
        // fills the loading state in place with no jump. A truly fresh present
        // (no loading) centers.
        let recenter = !isShowingLoading
        tearDownLoading()
        currentOnRetranslate = onRetranslate
        panel.contentView = makeResultContent(
            translation: translation, source: source, badge: badge, copied: copied,
            pair: pair, detected: detected, viaGoogleFallback: viaGoogleFallback,
            onSave: onSave
        )
        present(panel, recenter: recenter)
    }

    /// Shows the panel *immediately* in a loading state (TECH §8.1 / DESIGN §1):
    /// a spinning indeterminate `NSProgressIndicator` beside "Translating…" in the
    /// Translation slot, with the Recognized section already in place (empty until
    /// OCR lands). Called the instant a region is captured (`source: nil`), then
    /// again once OCR succeeds (`source:` = recognized text) to fill the Recognized
    /// section *in place* — no rebuild, no flicker. The real result later replaces
    /// this body via `showResult`, which keeps the panel where it is (no recenter),
    /// so the result fills in with no jump. Must be called on the main actor.
    @MainActor
    func showTranslating(source: String?) {
        let panel = panel ?? makePanel()
        self.panel = panel

        // Already loading → refresh the recognized text in place. `nil` (a fresh
        // capture, before OCR) must CLEAR it — otherwise actor reentrancy at the
        // OCR/translate await could leave the *previous* capture's recognized text
        // visible under "Translating…".
        if isShowingLoading {
            loadingSourceTextView?.string = source ?? ""
            present(panel, recenter: false)
            return
        }

        // Fresh loading body: drop any stale result/loading refs, then mount it and
        // center the panel — the result will fill this in place without recentering.
        dropResultBody()
        isShowingLoading = true
        panel.contentView = makeLoadingContent(source: source)
        present(panel, recenter: true)
    }

    /// Updates the already-mounted result body in place: swaps the translation /
    /// recognized text, rebuilds the lightweight header (badge / via / copied /
    /// save), and re-renders the language bar — without rebuilding the panel or
    /// re-creating the bar (so an open picker survives). Public so the retranslate
    /// completion path funnels through it; `showResult` calls it when a body
    /// already exists.
    @MainActor
    func updateResult(
        translation: String,
        source: String,
        badge: String,
        copied: Bool,
        pair: LanguagePair,
        detected: DetectedSource,
        viaGoogleFallback: Bool,
        onSave: (@MainActor () async -> Bool)?,
        onRetranslate: (@MainActor (LanguagePair) -> Void)?
    ) {
        currentOnRetranslate = onRetranslate
        if let headerStack {
            populateHeader(headerStack, badge: badge, copied: copied,
                           viaGoogleFallback: viaGoogleFallback, onSave: onSave)
        }
        if let translationTextView {
            translationTextView.string = translation
            translationTextView.textColor = .labelColor
        }
        sourceTextView?.string = source
        languageBarController?.update(pair: pair, detected: detected)
    }

    /// In-place "translating…" feedback for the gap between a language pick and
    /// the new result: dims the translation region without rebuilding the panel.
    /// Replaced by the real translation when `updateResult` lands (or by a fresh
    /// build on completion).
    @MainActor
    func setRetranslating() {
        guard let translationTextView else { return }
        translationTextView.string = "Translating…"
        translationTextView.textColor = .tertiaryLabelColor
    }

    /// Shows an error state — a title and message, no copy affordance.
    @MainActor
    func showError(title: String, message: String) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = makeMessageContent(title: title, body: message, isError: true)
        present(panel, recenter: true)
    }

    /// Back-compat informational message (permission/no-text/etc.).
    @MainActor
    func show(title: String, body: String) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = makeMessageContent(title: title, body: body, isError: false)
        present(panel, recenter: true)
    }

    /// Tears down the panel.
    @MainActor
    func close() {
        panel?.close()
        panel = nil
        dropResultBody()
    }

    // MARK: - Presentation

    /// Orders the panel front, centering it only on a fresh presentation. An
    /// in-place update (retranslate) keeps the panel where it is — recentering it
    /// mid-interaction would be jarring.
    @MainActor
    private func present(_ panel: KeyablePanel, recenter: Bool) {
        if recenter { panel.center() }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Forgets the live result body so the next `showResult` rebuilds it fresh
    /// (called when a message/error replaces a result, or on close). Also tears
    /// down any loading affordance, so a message/error/new-capture cleanly stops a
    /// running spinner.
    @MainActor
    private func dropResultBody() {
        saveButtonController = nil
        languageBarController = nil
        translationTextView = nil
        sourceTextView = nil
        headerStack = nil
        currentOnRetranslate = nil
        tearDownLoading()
    }

    /// Stops the loading spinner and forgets the loading body's refs, so the result
    /// (or error) that supersedes it leaves no animating indicator behind.
    @MainActor
    private func tearDownLoading() {
        loadingSpinner?.stopAnimation(nil)
        loadingSpinner = nil
        loadingSourceTextView = nil
        isShowingLoading = false
    }

    // MARK: - Construction

    @MainActor
    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
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

    /// Result layout: badge + "Copied ✓" header row, the From/To language bar,
    /// then two clearly-labeled, legible sections — a "Translation" caption over
    /// the primary translation and a "Recognized" caption over the OCR original.
    /// The recognized text is shown at a readable size so the user can compare it
    /// against the translation and tell whether a bad result came from OCR or the
    /// engine. Both scroll views hold a real minimum height so neither section can
    /// collapse. When `onSave` is provided the header gains a "Save to Notebook"
    /// button (⌘S). Builds the body once and stores references so a retranslate
    /// can refresh it in place (`updateResult`).
    @MainActor
    private func makeResultContent(
        translation: String, source: String, badge: String, copied: Bool,
        pair: LanguagePair, detected: DetectedSource, viaGoogleFallback: Bool,
        onSave: (@MainActor () async -> Bool)?
    ) -> NSView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        populateHeader(header, badge: badge, copied: copied,
                       viaGoogleFallback: viaGoogleFallback, onSave: onSave)
        headerStack = header

        // The From/To bar + searchable picker. A pick shows in-place "translating…"
        // feedback, then fires the result's retranslate hook. Recents are read
        // fresh each time the picker opens (the coordinator records the active
        // target before presenting, so it is already pinned).
        let barController = LanguageBarController(
            pair: pair, detected: detected,
            recentProvider: { [settings] in settings.recentTargets }
        )
        barController.onPick = { [weak self] newPair in
            guard let self else { return }
            self.setRetranslating()
            self.currentOnRetranslate?(newPair)
        }
        languageBarController = barController

        let translationCaption = sectionCaption("Translation")
        let translationView = scrollableText(
            translation, fontSize: 18, dim: false, minHeight: Layout.minSectionHeight
        )
        translationTextView = translationView.documentView as? NSTextView

        let sourceCaption = sectionCaption("Recognized")
        let sourceView = scrollableText(
            source, fontSize: 14, dim: true, minHeight: Layout.minSectionHeight
        )
        sourceTextView = sourceView.documentView as? NSTextView

        let stack = verticalStack([
            header, barController.view,
            translationCaption, translationView, sourceCaption, sourceView,
        ])
        stack.setCustomSpacing(10, after: header)
        stack.setCustomSpacing(12, after: barController.view)
        // Tight caption→content pairing; breathing room between the two sections.
        stack.setCustomSpacing(2, after: translationCaption)
        stack.setCustomSpacing(14, after: translationView)
        stack.setCustomSpacing(2, after: sourceCaption)
        return wrap(stack, stretching: [barController.view, translationView, sourceView])
    }

    /// The instant loading body shown the moment a region is captured: a spinning
    /// indeterminate indicator beside "Translating…" occupies the Translation slot,
    /// and the Recognized section is mounted up front (empty until OCR lands) so
    /// filling it in place doesn't shift the layout. Deliberately omits the language
    /// bar/badge (the effective pair + engine aren't known until translation
    /// returns); the real result body — built fresh by `makeResultContent` — adds
    /// them when it supersedes this in place.
    @MainActor
    private func makeLoadingContent(source: String?) -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        loadingSpinner = spinner

        let translatingLabel = NSTextField(labelWithString: "Translating…")
        translatingLabel.font = .systemFont(ofSize: 18)
        translatingLabel.textColor = .tertiaryLabelColor

        let translatingRow = NSStackView(views: [spinner, translatingLabel])
        translatingRow.orientation = .horizontal
        translatingRow.alignment = .centerY
        translatingRow.spacing = 8

        let translationCaption = sectionCaption("Translation")
        let sourceCaption = sectionCaption("Recognized")
        let sourceView = scrollableText(
            source ?? "", fontSize: 14, dim: true, minHeight: Layout.minSectionHeight
        )
        loadingSourceTextView = sourceView.documentView as? NSTextView

        let stack = verticalStack([
            translationCaption, translatingRow, sourceCaption, sourceView,
        ])
        stack.setCustomSpacing(2, after: translationCaption)
        stack.setCustomSpacing(14, after: translatingRow)
        stack.setCustomSpacing(2, after: sourceCaption)
        return wrap(stack, stretching: [sourceView])
    }

    /// (Re)populates the header row: engine badge, an optional faint "via Google"
    /// note (an AI-preferred pair routed to Google — TECH §4), the "Copied ✓"
    /// affordance, a flexible spacer, and the opt-in Save button. Clears any prior
    /// subviews + Save controller first so it is safe to call on an in-place
    /// update as well as a fresh build.
    @MainActor
    func populateHeader(
        _ header: NSStackView, badge: String, copied: Bool,
        viaGoogleFallback: Bool, onSave: (@MainActor () async -> Bool)?
    ) {
        for subview in header.arrangedSubviews {
            header.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        saveButtonController = nil

        header.addArrangedSubview(badgeView(badge))
        if viaGoogleFallback {
            header.addArrangedSubview(viaGoogleLabel())
        }
        if copied {
            header.addArrangedSubview(copiedLabel())
        }
        header.addArrangedSubview(spacer())
        if let onSave {
            header.addArrangedSubview(saveControl(onSave: onSave))
        }
    }

    /// Title + body layout for info/error states.
    @MainActor
    private func makeMessageContent(title: String, body: String, isError: Bool) -> NSView {
        // A message/error replaces any savable result — drop the whole result body
        // so the next result rebuilds fresh (and the bar controller is released).
        dropResultBody()

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = isError ? .systemRed : .secondaryLabelColor

        let bodyView = scrollableText(body, fontSize: 14, dim: false)

        let stack = verticalStack([titleLabel, bodyView])
        return wrap(stack, mainView: bodyView)
    }

    // MARK: - View helpers

    /// The badge tint for an engine label: purple for the AI engine, blue for the
    /// always-on FREE engine. Pure so the FREE-vs-AI rendering is unit-testable
    /// without mounting the panel.
    static func badgeColor(for badge: String) -> NSColor {
        badge == "AI" ? .systemPurple : .systemBlue
    }

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
        container.layer?.backgroundColor = Self.badgeColor(for: text).cgColor
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

    /// A small semibold section caption (e.g. "Translation", "Recognized") in
    /// `.secondaryLabelColor` — legible enough to label a section without
    /// competing with its content.
    @MainActor
    private func sectionCaption(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    @MainActor
    private func copiedLabel() -> NSView {
        let label = NSTextField(labelWithString: "Copied ✓")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .systemGreen
        return label
    }

    /// A faint "via Google" note shown on the badge row when an AI-preferred pair
    /// was served by Google (TECH §4). Minimal placement for now; slice 7's
    /// language bar gives it a permanent home.
    @MainActor
    private func viaGoogleLabel() -> NSView {
        let label = NSTextField(labelWithString: "via Google")
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.toolTip = "The AI engine can’t serve this pair — translated with Google."
        return label
    }

    @MainActor
    private func savedLabel() -> NSView {
        // "★ Saved to Notebook" — the confirmed state shown after the user opts
        // in via the Save button, beside "Copied ✓" without competing with the
        // translation.
        let label = NSTextField(labelWithString: "★ Saved")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .systemPurple
        label.toolTip = "Saved to Notebook"
        return label
    }

    /// Builds the opt-in "Save to Notebook" control: a ⌘S button backed by a
    /// `SaveButtonController` that runs `onSave` and swaps the control to the
    /// confirmed "★ Saved" state (or shows an inline error on failure). The
    /// controller is stored on `self` (`saveButtonController`) so it outlives this
    /// call — an `NSButton.target` is a non-owning reference.
    @MainActor
    private func saveControl(onSave: @escaping @MainActor () async -> Bool) -> NSView {
        let controller = SaveButtonController(onSave: onSave, savedLabel: savedLabel)
        saveButtonController = controller
        return controller.view
    }

    @MainActor
    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    /// A non-editable, selectable, scrolling text region. `dim` renders the text
    /// in `.secondaryLabelColor` (still readable) rather than primary
    /// `.labelColor`. When `minHeight` is set the scroll view is pinned to at
    /// least that height so it can't be squeezed to near-zero — the surrounding
    /// stack/panel grows or scrolls to honor it.
    @MainActor
    private func scrollableText(
        _ string: String, fontSize: CGFloat, dim: Bool, minHeight: CGFloat? = nil
    ) -> NSScrollView {
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
        if let minHeight {
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight)
                .isActive = true
        }
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
        wrap(stack, stretching: [mainView])
    }

    /// Pins a stack to fill the content view and makes each view in `stretchers`
    /// span the full content width, so every wrapped-text region uses the panel
    /// width (not just the first). Used by the result layout, where both the
    /// translation and the recognized-source scroll views must stretch.
    @MainActor
    private func wrap(_ stack: NSStackView, stretching stretchers: [NSView]) -> NSView {
        let content = NSView()
        content.addSubview(stack)
        let insetWidth = -(stack.edgeInsets.left + stack.edgeInsets.right)
        var constraints: [NSLayoutConstraint] = [
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ]
        constraints += stretchers.map { view in
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: insetWidth)
        }
        NSLayoutConstraint.activate(constraints)
        return content
    }
}

/// Owns the opt-in "Save to Notebook" button and its lifecycle.
///
/// A small horizontal stack holding the ⌘S button (plus a transient inline error
/// label on failure). On click it disables the button, awaits the async save
/// handler, then either swaps the button for the confirmed "★ Saved" label (so a
/// second click can't create a duplicate) or re-enables the button and surfaces a
/// red "Couldn't save" label to retry. The button's `target` is this controller;
/// `ResultPanel` holds the strong reference (in `saveButtonController`) that keeps
/// it alive for the lifetime of the shown result.
@MainActor
private final class SaveButtonController {

    /// The view the result header embeds.
    let view: NSStackView

    private let onSave: @MainActor () async -> Bool
    private let makeSavedLabel: @MainActor () -> NSView
    private let button: NSButton
    private var isSaving = false

    init(onSave: @escaping @MainActor () async -> Bool, savedLabel: @escaping @MainActor () -> NSView) {
        self.onSave = onSave
        self.makeSavedLabel = savedLabel

        let button = NSButton(title: "Save to Notebook", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.keyEquivalent = "s"
        button.keyEquivalentModifierMask = .command
        button.toolTip = "Save to Notebook (⌘S)"
        self.button = button

        let stack = NSStackView(views: [button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        self.view = stack

        // `objc` action wiring: the controller is the (non-owning) target, kept
        // alive by `ResultPanel.saveButtonController`.
        button.target = self
        button.action = #selector(saveTapped)
    }

    @objc private func saveTapped() {
        guard !isSaving else { return }
        isSaving = true
        button.isEnabled = false
        clearError()

        Task { @MainActor in
            let ok = await onSave()
            isSaving = false
            if ok {
                confirmSaved()
            } else {
                button.isEnabled = true
                showError()
            }
        }
    }

    /// Replaces the button with the disabled confirmed "★ Saved" affordance.
    private func confirmSaved() {
        clearError()
        view.removeArrangedSubview(button)
        button.removeFromSuperview()
        view.addArrangedSubview(makeSavedLabel())
    }

    private var errorLabel: NSTextField?

    private func showError() {
        guard errorLabel == nil else { return }
        let label = NSTextField(labelWithString: "Couldn’t save")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .systemRed
        label.toolTip = "Saving to the notebook failed — try again"
        errorLabel = label
        view.addArrangedSubview(label)
    }

    private func clearError() {
        errorLabel?.removeFromSuperview()
        errorLabel = nil
    }
}
