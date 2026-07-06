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

        /// Clears any active selection in the (non-editable but selectable)
        /// "Recognized"/"Translation" text views when the user clicks outside
        /// them — the standard macOS popup behavior. Without this a selection
        /// persists until *another* text view is clicked, because nothing in the
        /// surrounding chrome resigns first responder. Handled in `sendEvent` so
        /// the click is seen before any subview (caption, button, language bar)
        /// can consume it; the event is always forwarded to `super` so normal
        /// dispatch (button presses, text selection, scrolling) is untouched.
        override func sendEvent(_ event: NSEvent) {
            if event.type == .leftMouseDown, let contentView {
                let point = contentView.convert(event.locationInWindow, from: nil)
                if ResultPanel.shouldClearSelection(forHit: contentView.hitTest(point)) {
                    clearTextSelection(in: contentView)
                }
            }
            super.sendEvent(event)
        }

        /// Collapses every descendant text view's selection and drops
        /// first-responder focus — but only when something was actually selected,
        /// so an ordinary click in empty space doesn't needlessly steal focus
        /// (e.g. from an open picker's search field).
        private func clearTextSelection(in root: NSView) {
            var didClear = false
            func visit(_ view: NSView) {
                if let textView = view as? NSTextView, textView.selectedRange().length > 0 {
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                    didClear = true
                }
                view.subviews.forEach(visit)
            }
            visit(root)
            if didClear { makeFirstResponder(nil) }
        }
    }

    /// Whether a left-click that resolved to `hitView` should clear an active
    /// text selection. Clicks that land inside a selectable `NSTextView` (or on a
    /// scroller, so dragging to scroll doesn't wipe the selection) keep it; clicks
    /// anywhere else in the panel — captions, header, language bar, empty area —
    /// clear it. Walks up the view's ancestry so a hit on a text view's internal
    /// subview still counts as "inside the text". Pure + static so the deselect
    /// decision is unit-testable without mounting a window.
    static func shouldClearSelection(forHit hitView: NSView?) -> Bool {
        var view = hitView
        while let current = view {
            if current is NSTextView || current is NSScroller { return false }
            view = current.superview
        }
        return true
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

    /// Read-aloud engine behind the Translation / Recognized speaker buttons.
    /// Injected so the speaker wiring is testable with a spy; defaults to the
    /// real `AVSpeechSynthesizer`-backed service.
    private let speech: SpeechSynthesizing

    // `speech` defaults to `nil` (not `SpeechService()`): a default-argument
    // expression is evaluated in a nonisolated context, but `SpeechService` is
    // main-actor isolated, so it's constructed inside this `@MainActor` init body.
    @MainActor
    init(settings: SettingsStore = SettingsStore(), speech: SpeechSynthesizing? = nil) {
        self.settings = settings
        self.speech = speech ?? SpeechService()
        super.init()
        // Reset the active speaker icon when an utterance ends on its own.
        self.speech.onFinish = { [weak self] in self?.handleSpeechFinished() }
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

    /// Which pane the read-aloud feature can speak. Drives the per-section speaker
    /// button (which text view to read, which language voice to use, and whether a
    /// button is offered at all).
    private enum SpeakSection { case translation, source }

    /// The BCP-47 codes to voice each pane in: the translation in the target
    /// language, the recognized text in the detected/source language. Updated on
    /// a retranslate so a re-tap reads the *current* result in the *current*
    /// language. `nil` (unknown source) falls back to the system default voice.
    private var translationLangCode: String?
    private var sourceLangCode: String?

    /// The live speaker buttons, held so their icon can toggle (speaker ⇄ stop)
    /// and their visibility can track voice availability across a retranslate.
    /// Weak: the view hierarchy owns them.
    private weak var translationSpeakerButton: NSButton?
    private weak var sourceSpeakerButton: NSButton?

    /// The pane currently being read aloud, or `nil` when silent. Drives which
    /// button shows the "stop" icon and lets a re-tap on the active pane stop it.
    private var activeSpeakSection: SpeakSection?

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
        // The result is changing under any in-progress read-aloud — stop it, then
        // re-point the speakers at the new languages and hide any that the system
        // can't voice for the retranslated pair.
        haltSpeech()
        translationLangCode = pair.to.code
        sourceLangCode = detected.languageCode ?? pair.from?.code
        translationSpeakerButton?.isHidden = !speech.canSpeak(languageCode: translationLangCode)
        sourceSpeakerButton?.isHidden = !speech.canSpeak(languageCode: sourceLangCode)
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
        // The result is about to change — silence any read-aloud now (and reset the
        // "stop" icon) rather than letting stale audio run until the new result lands.
        haltSpeech()
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

    /// `NSWindowDelegate`: the native title-bar close button doesn't route through
    /// `close()` (nothing calls that in production), so stop any read-aloud here.
    /// Dismissing the surface must silence it — matching every other dismissal
    /// path (new capture, error, message) and Google-Translate behavior, where the
    /// only stop control (the speaker button) is gone once the window closes.
    @MainActor
    func windowWillClose(_ notification: Notification) {
        haltSpeech()
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
        haltSpeech()
        saveButtonController = nil
        languageBarController = nil
        translationTextView = nil
        sourceTextView = nil
        headerStack = nil
        currentOnRetranslate = nil
        translationSpeakerButton = nil
        sourceSpeakerButton = nil
        translationLangCode = nil
        sourceLangCode = nil
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

        // Read-aloud languages: the translation in the target language, the
        // recognized text in the detected source (falling back to the explicit
        // From). Stored so a retranslate's re-tap reads the current result. Stop
        // any lingering utterance so a fresh body starts silent.
        speech.stop()
        activeSpeakSection = nil
        translationLangCode = pair.to.code
        sourceLangCode = detected.languageCode ?? pair.from?.code

        let translationCaption = captionRow(
            "Translation", section: .translation, code: translationLangCode
        )
        let translationView = scrollableText(
            translation, fontSize: 18, dim: false, minHeight: Layout.minSectionHeight
        )
        translationTextView = translationView.documentView as? NSTextView

        let sourceCaption = captionRow("Recognized", section: .source, code: sourceLangCode)
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
        return wrap(stack, stretching: [
            barController.view, translationCaption, translationView, sourceCaption, sourceView,
        ])
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
    /// competing with its content. Used by the loading body; the result body uses
    /// `captionRow`, which adds a read-aloud speaker button.
    @MainActor
    private func sectionCaption(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: - Read aloud

    /// A section caption with a trailing read-aloud speaker button (mirroring
    /// Google Translate). The button is hidden when the system has no voice for
    /// `code` — an offered button that stays silent is worse than none. The button
    /// reads the pane's *live* text (so a retranslate reads the new result) in the
    /// pane's language; a second tap on a reading pane stops it.
    @MainActor
    private func captionRow(_ title: String, section: SpeakSection, code: String?) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let button = makeSpeakerButton(section: section)
        button.isHidden = !speech.canSpeak(languageCode: code)
        switch section {
        case .translation: translationSpeakerButton = button
        case .source: sourceSpeakerButton = button
        }

        let row = NSStackView(views: [label, spacer(), button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    /// A borderless SF Symbol speaker button wired to the pane's speak action.
    @MainActor
    private func makeSpeakerButton(section: SpeakSection) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.image = speakerIcon(speaking: false)
        button.toolTip = "Read aloud"
        button.setAccessibilityLabel("Read aloud")
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.target = self
        button.action = section == .translation
            ? #selector(speakTranslationTapped)
            : #selector(speakSourceTapped)
        return button
    }

    /// The speaker glyph: a stop square while that pane is being read, else the
    /// speaker wave. Sized down to sit quietly beside the 11pt caption.
    @MainActor
    private func speakerIcon(speaking: Bool) -> NSImage? {
        let name = speaking ? "stop.fill" : "speaker.wave.2.fill"
        let description = speaking ? "Stop reading" : "Read aloud"
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
    }

    @objc private func speakTranslationTapped() { toggleSpeak(.translation) }
    @objc private func speakSourceTapped() { toggleSpeak(.source) }

    /// Starts reading a pane, or stops it if it's already the one being read.
    /// Switching panes interrupts the first. Reads the text view's current string
    /// so an in-place retranslate is spoken correctly; no-op on empty text.
    @MainActor
    private func toggleSpeak(_ section: SpeakSection) {
        if activeSpeakSection == section {
            speech.stop()
            activeSpeakSection = nil
            refreshSpeakerIcons()
            return
        }

        let text: String?
        let code: String?
        switch section {
        case .translation:
            text = translationTextView?.string
            code = translationLangCode
        case .source:
            text = sourceTextView?.string
            code = sourceLangCode
        }

        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speech.speak(trimmed, languageCode: code)
        activeSpeakSection = section
        refreshSpeakerIcons()
    }

    /// Reset the speaker state when an utterance ends on its own.
    @MainActor
    private func handleSpeechFinished() {
        activeSpeakSection = nil
        refreshSpeakerIcons()
    }

    /// Stops any read-aloud in progress and resets the icons — called when the
    /// shown result changes out from under it (retranslate / new capture / close).
    @MainActor
    private func haltSpeech() {
        guard activeSpeakSection != nil else { return }
        speech.stop()
        activeSpeakSection = nil
        refreshSpeakerIcons()
    }

    /// Repaints both speaker buttons for the current `activeSpeakSection` (the
    /// reading pane shows "stop", the others "speaker").
    @MainActor
    private func refreshSpeakerIcons() {
        applySpeakerState(translationSpeakerButton, reading: activeSpeakSection == .translation)
        applySpeakerState(sourceSpeakerButton, reading: activeSpeakSection == .source)
    }

    /// Syncs a speaker button's icon, tooltip, and — crucially — its VoiceOver
    /// label to the reading state. The accessibility label must flip too: an
    /// explicitly-set `NSButton` label overrides the image's description, so
    /// without this VoiceOver would keep announcing "Read aloud" on a button that
    /// now stops playback.
    @MainActor
    private func applySpeakerState(_ button: NSButton?, reading: Bool) {
        guard let button else { return }
        button.image = speakerIcon(speaking: reading)
        button.toolTip = reading ? "Stop" : "Read aloud"
        button.setAccessibilityLabel(reading ? "Stop reading" : "Read aloud")
    }

    // MARK: - Read-aloud test seams

    // Internal (not private) so `@testable` tests can drive the speaker wiring
    // headlessly: build a result body (which sets up the text views + speaker
    // buttons), trigger a pane's speaker, and inspect the resulting state —
    // without presenting an `NSPanel`. Not part of the production surface.

    /// Builds and returns a result body without presenting a window. The caller
    /// must retain the returned view (the panel holds only weak references into
    /// it, mirroring the live view hierarchy).
    @MainActor
    func buildResultBodyForTests(
        translation: String, source: String, pair: LanguagePair, detected: DetectedSource
    ) -> NSView {
        makeResultContent(
            translation: translation, source: source, badge: "AI", copied: false,
            pair: pair, detected: detected, viaGoogleFallback: false, onSave: nil
        )
    }

    @MainActor func tapTranslationSpeakerForTests() { toggleSpeak(.translation) }
    @MainActor func tapSourceSpeakerForTests() { toggleSpeak(.source) }

    @MainActor var translationSpeakerIsHiddenForTests: Bool? { translationSpeakerButton?.isHidden }
    @MainActor var sourceSpeakerIsHiddenForTests: Bool? { sourceSpeakerButton?.isHidden }
    @MainActor var isReadingTranslationForTests: Bool { activeSpeakSection == .translation }
    @MainActor var isReadingSourceForTests: Bool { activeSpeakSection == .source }

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
