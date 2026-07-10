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
        onRetranslate: (@MainActor (LanguagePair) -> Void)?,
        selection: SelectionHooks?
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

/// What a selection lookup produced, as the panel consumes it (TECH §F-3).
/// The coordinator maps service throws/staleness into exactly one case; the
/// panel renders `.success`/`.failure` and ignores `.superseded` outright — a
/// newer request owns the slot.
enum SelectionLookupOutcome {
    case success(SelectionResult)
    case failure(Error)
    case superseded
}

/// The selection hand-off `CaptureCoordinator` builds at present time
/// (mirroring `onSave`/`onRetranslate`): `translate` runs one span lookup with
/// the capture's context/pair pre-captured behind the closure; `save` persists
/// a card save (`nil` ⇒ no notebook, so the card offers no Save control).
struct SelectionHooks {
    let translate: @MainActor (String) async -> SelectionLookupOutcome
    let save: (@MainActor (_ source: String, _ translation: String, _ servedBy: EngineKind) async -> Bool)?
}

/// The translation result UI (TECH §8.1).
///
/// An `NSPanel` subclass that *can become key* — an `LSUIElement` agent app has
/// no main window, so the panel must be allowed to take focus explicitly (the
/// coordinator calls `NSApp.activate` first). Slice 3 renders a translation
/// result: the translation large/primary, the recognized source dim/smaller, an
/// engine badge (FREE/AI), and a "Copied ✓" affordance once the translation is
/// on the pasteboard. Errors render as a distinct error state.
final class ResultPanel: NSObject, NSWindowDelegate, NSTextViewDelegate, ResultPresenting {

    /// A borderless utility panel that is allowed to become key/main despite the
    /// app having no Dock presence.
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }

        /// Fired after every left mouse-up — the reliable end-of-drag trigger
        /// for a selection (`textViewDidChangeSelection` fires mid-drag; the
        /// mouse-up is what says the drag settled — TECH Fig. F2). Observation
        /// only: the event is always forwarded to `super`.
        var onLeftMouseUp: (() -> Void)?

        /// Esc handling while a selection card is active: returns `true` when
        /// the cancel was consumed (a card was dismissed). `false`/`nil` falls
        /// through to `super` — today's Esc behavior untouched (TECH §F-6).
        var onCancel: (() -> Bool)?

        /// Clears any active selection in the (non-editable but selectable)
        /// "Recognized"/"Translation" text views when the user clicks outside
        /// them — the standard macOS popup behavior. Without this a selection
        /// persists until *another* text view is clicked, because nothing in the
        /// surrounding chrome resigns first responder. Handled in `sendEvent` so
        /// the click is seen before any subview (caption, button, language bar)
        /// can consume it; the event is always forwarded to `super` so normal
        /// dispatch (button presses, text selection, scrolling) is untouched.
        /// A left mouse-up is noticed *after* `super` has dispatched it, so the
        /// text view's selection is final when the selection hook reads it.
        override func sendEvent(_ event: NSEvent) {
            if event.type == .leftMouseDown, let contentView {
                let point = contentView.convert(event.locationInWindow, from: nil)
                if ResultPanel.shouldClearSelection(forHit: contentView.hitTest(point)) {
                    clearTextSelection(in: contentView)
                }
            }
            super.sendEvent(event)
            if event.type == .leftMouseUp { onLeftMouseUp?() }
        }

        override func cancelOperation(_ sender: Any?) {
            if onCancel?() == true { return }
            super.cancelOperation(sender)
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
    /// scroller, so dragging to scroll doesn't wipe the selection — or inside the
    /// selection card, whose visual anchor IS the selection) keep it; clicks
    /// anywhere else in the panel — captions, header, language bar, empty area —
    /// clear it. Walks up the view's ancestry so a hit on a text view's internal
    /// subview still counts as "inside the text". Pure + static so the deselect
    /// decision is unit-testable without mounting a window.
    static func shouldClearSelection(forHit hitView: NSView?) -> Bool {
        var view = hitView
        while let current = view {
            if current is NSTextView || current is NSScroller { return false }
            if current is SelectionCardView { return false }
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
        /// The selection card slot never exceeds this (DESIGN §02): pathological
        /// content is clamped inside the card, never scrolled.
        static let maxCardSlotHeight: CGFloat = 200
        /// Gap between the Recognized section and the card slot (TECH §F-1).
        static let cardSlotSpacing: CGFloat = 12
        /// Slot growth animation (DESIGN §02 timing.motion): 180 ms ease-out.
        /// Shrink on dismissal and Reduce Motion are always instant.
        static let cardGrowDuration: TimeInterval = 0.18
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

    /// IPA phonetic lookup behind the per-pane phonetic line (音标). Injected for
    /// testability; defaults to the real bundled-dictionary service.
    private let phonetic: PhoneticProviding

    // `speech`/`phonetic` default to `nil` (not their concrete types): a
    // default-argument expression is evaluated in a nonisolated context, but the
    // services are actor/main-actor isolated, so they're constructed inside this
    // `@MainActor` init body.
    @MainActor
    init(
        settings: SettingsStore = SettingsStore(),
        speech: SpeechSynthesizing? = nil,
        phonetic: PhoneticProviding? = nil
    ) {
        self.settings = settings
        self.speech = speech ?? SpeechService()
        self.phonetic = phonetic ?? PhoneticService()
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

    /// The dim IPA phonetic line under each pane (音标), shown only when the pane's
    /// language is English. Weak: the view hierarchy owns them.
    private weak var translationPhoneticLabel: NSTextField?
    private weak var sourcePhoneticLabel: NSTextField?

    /// Bumped whenever the result body changes (fresh build / retranslate /
    /// teardown). The async IPA fill captures the value at launch and only applies
    /// its result if still current — so a slow lookup for a superseded result can't
    /// paint onto the new one.
    private var phoneticGeneration = 0

    // MARK: - Contextual-selection state (TECH §F-1 "new members")

    /// The mounted selection card, if any. Weak: the result stack owns it.
    private weak var selectionCard: SelectionCardView?

    /// The live result body's outer stack and its Recognized section, kept so
    /// the card slot can mount lazily after the Recognized pane on the first
    /// fire (TECH §F-1 — nothing is constructed before then, FR-8). Weak: the
    /// view hierarchy owns them; swapping the content view auto-nils them.
    private weak var resultStack: NSStackView?
    private weak var sourceSectionView: NSView?

    /// The card slot's height constraint — re-measured when content lands and
    /// adjusted only on a real difference (Fig. F4).
    private var selectionSlotHeightConstraint: NSLayoutConstraint?

    /// The 300 ms settle task armed by selection changes / mouse-up (Fig. F2).
    private var selectionSettleTask: Task<Void, Never>?

    /// The in-flight lookup task — cancelled on a re-fire and by the dismissal
    /// sink, so at most one request is ever in flight (FR-1).
    private var selectionTask: Task<Void, Never>?

    /// Mirror of `phoneticGeneration` for the card: a lookup captures the value
    /// at fire time and its outcome is applied only while still current (AC-7).
    private var selectionUIGeneration = 0

    /// Identical-span dedupe key (`SpanNormalizer.normalize`d at fire time).
    private var lastFiredSpan: String?

    /// The selection hand-off for the live result. `nil` (every pre-selection
    /// call site) leaves the whole feature unreachable (FR-8/AC-8).
    private var currentSelectionHooks: SelectionHooks?

    /// The panel frame before the card grew it — dismissal restores it exactly.
    private var frameBeforeSelectionGrowth: NSRect?

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
        onRetranslate: (@MainActor (LanguagePair) -> Void)? = nil,
        selection: SelectionHooks? = nil
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
                onSave: onSave, onRetranslate: onRetranslate, selection: selection
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
        currentSelectionHooks = selection
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
        onRetranslate: (@MainActor (LanguagePair) -> Void)?,
        selection: SelectionHooks? = nil
    ) {
        // The content is changing under any active card — dismiss it FIRST so a
        // stale card can never sit over the new result, even briefly (FR-6).
        dismissSelectionCard()
        currentSelectionHooks = selection
        wireSelectionTrigger()
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
        refreshPhonetics(translation: translation, source: source)
    }

    /// In-place "translating…" feedback for the gap between a language pick and
    /// the new result: dims the translation region without rebuilding the panel.
    /// Replaced by the real translation when `updateResult` lands (or by a fresh
    /// build on completion).
    @MainActor
    func setRetranslating() {
        // The result is about to change — a card answering the old text must go
        // now, before the in-place feedback paints (FR-6, TECH §F-6).
        dismissSelectionCard()
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
    /// running spinner. Internal (not private): it is one of the three teardown
    /// funnels the selection tests drive directly (TECH I-13).
    @MainActor
    func dropResultBody() {
        // One dismissal system: the card can never outlive its content (FR-6).
        dismissSelectionCard()
        currentSelectionHooks = nil
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
        // Invalidate any in-flight phonetic fill so it can't paint onto a rebuilt body.
        phoneticGeneration += 1
        translationPhoneticLabel = nil
        sourcePhoneticLabel = nil
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
        // Selection wiring (TECH §F-2/§F-6): both handlers are inert until a
        // result presented with hooks arms the feature — pure observation before.
        panel.onLeftMouseUp = { [weak self] in self?.handleLeftMouseUp() }
        panel.onCancel = { [weak self] in
            guard let self, self.selectionCard != nil else { return false }
            self.dismissSelectionCard()
            return true
        }
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
        let translationPhonetic = makePhoneticLabel()
        translationPhoneticLabel = translationPhonetic

        let sourceCaption = captionRow("Recognized", section: .source, code: sourceLangCode)
        let sourceView = scrollableText(
            source, fontSize: 14, dim: true, minHeight: Layout.minSectionHeight
        )
        sourceTextView = sourceView.documentView as? NSTextView
        let sourcePhonetic = makePhoneticLabel()
        sourcePhoneticLabel = sourcePhonetic

        // Each pane is its own sub-stack (caption → text → phonetic) so hiding the
        // phonetic line collapses only *inside* the pane — the inter-section gap is
        // set between the two sub-stacks and stays put whether or not a phonetic
        // line shows.
        let translationSection = paneStack([translationCaption, translationView, translationPhonetic])
        let sourceSection = paneStack([sourceCaption, sourceView, sourcePhonetic])

        let stack = verticalStack([header, barController.view, translationSection, sourceSection])
        stack.setCustomSpacing(10, after: header)
        stack.setCustomSpacing(12, after: barController.view)
        stack.setCustomSpacing(14, after: translationSection)

        // The card slot mounts lazily after the Recognized section on the first
        // selection fire — keep the anchors (TECH §F-1) and wire the trigger.
        resultStack = stack
        sourceSectionView = sourceSection
        wireSelectionTrigger()

        // Fill the phonetic lines (async; English-only, hidden otherwise).
        refreshPhonetics(translation: translation, source: source)

        return wrap(stack, stretching: [barController.view, translationSection, sourceSection])
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

    // MARK: - Phonetics (IPA)

    /// A dim, wrapping, selectable label for the IPA phonetic line under a pane.
    /// Starts hidden; the async fill reveals it only when there's a transcription.
    /// Capped at 3 lines so a long transcription truncates cleanly instead of
    /// growing unbounded and overflowing the fixed-size panel.
    @MainActor
    private func makePhoneticLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 3
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = true
        label.isHidden = true
        label.setAccessibilityLabel("Phonetic transcription")
        return label
    }

    /// Recomputes both phonetic lines for the current result. Bumps the generation
    /// so any in-flight fill for a superseded result is discarded when it returns.
    @MainActor
    private func refreshPhonetics(translation: String, source: String) {
        phoneticGeneration += 1
        let generation = phoneticGeneration
        loadPhonetic(.translation, text: translation, code: translationLangCode, generation: generation)
        loadPhonetic(.source, text: source, code: sourceLangCode, generation: generation)
    }

    /// English panes get an async IPA lookup; everything else is hidden outright
    /// (no dictionary, no line). The result is applied only if the generation is
    /// still current.
    @MainActor
    private func loadPhonetic(_ section: SpeakSection, text: String, code: String?, generation: Int) {
        guard PhoneticLanguage.isEnglish(code) else {
            renderPhonetic(section, ipa: nil)
            return
        }
        Task { [weak self, phonetic] in
            let ipa = await phonetic.ipa(for: text, languageCode: code)
            guard let self, self.phoneticGeneration == generation else { return }
            self.renderPhonetic(section, ipa: ipa)
        }
    }

    /// Shows the pane's phonetic line wrapped in `/ … /`, or hides it when there's
    /// no transcription.
    @MainActor
    private func renderPhonetic(_ section: SpeakSection, ipa: String?) {
        let label = section == .translation ? translationPhoneticLabel : sourcePhoneticLabel
        guard let label else { return }
        if let ipa, !ipa.isEmpty {
            label.stringValue = "/\(ipa)/"
            label.isHidden = false
        } else {
            label.stringValue = ""
            label.isHidden = true
        }
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

    /// Applies an IPA string to a pane's phonetic line as the async fill would,
    /// so the render (wrap in `/ … /`, show/hide) is testable without awaiting a
    /// fire-and-forget Task. `which`: `true` = translation, `false` = source.
    @MainActor func renderPhoneticForTests(translation which: Bool, ipa: String?) {
        renderPhonetic(which ? .translation : .source, ipa: ipa)
    }

    @MainActor var translationPhoneticTextForTests: String? { translationPhoneticLabel?.stringValue }
    @MainActor var sourcePhoneticTextForTests: String? { sourcePhoneticLabel?.stringValue }
    @MainActor var translationPhoneticHiddenForTests: Bool? { translationPhoneticLabel?.isHidden }
    @MainActor var sourcePhoneticHiddenForTests: Bool? { sourcePhoneticLabel?.isHidden }

    @MainActor var translationSpeakerIsHiddenForTests: Bool? { translationSpeakerButton?.isHidden }
    @MainActor var sourceSpeakerIsHiddenForTests: Bool? { sourceSpeakerButton?.isHidden }
    @MainActor var isReadingTranslationForTests: Bool { activeSpeakSection == .translation }
    @MainActor var isReadingSourceForTests: Bool { activeSpeakSection == .source }

    // MARK: - Contextual selection — observation (TECH §F-2)

    /// Whether a settled selection should fire a lookup (Fig. F2's guards):
    /// empty and punctuation-only spans never fire (DESIGN §06 — nothing to
    /// translate); an identical span while the slot is visible is deduped (the
    /// existing card already answers it); the same span fires again after a
    /// dismissal; anything else fires. Pure + static so the fire decision is
    /// unit-testable without a window, exactly like `shouldClearSelection`.
    static func shouldFireSelection(normalizedSpan: String, lastFired: String?, slotVisible: Bool) -> Bool {
        guard normalizedSpan.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        if slotVisible, normalizedSpan == lastFired { return false }
        return true
    }

    /// Selection changes in the two result panes. The Recognized pane is the
    /// only trigger surface: a collapse dismisses the card at once (no
    /// debounce), a mid-drag change only disarms the settle task (never fire
    /// mid-drag — FR-1, cost guard), and a settled change (mouse or ⇧←/→)
    /// re-arms it. A non-empty selection in the Translation pane dismisses an
    /// active card (TECH §F-6) and triggers nothing.
    @MainActor
    func textViewDidChangeSelection(_ notification: Notification) {
        guard currentSelectionHooks != nil,
              let textView = notification.object as? NSTextView else { return }
        if textView === translationTextView {
            if textView.selectedRange().length > 0 { dismissSelectionCard() }
            return
        }
        guard textView === sourceTextView else { return }
        guard !SpanNormalizer.normalize(recognizedSelection()).isEmpty else {
            dismissSelectionCard() // selection collapse kills the card, no debounce
            return
        }
        guard NSEvent.pressedMouseButtons & 1 == 0 else {
            // Drag in progress: stand down; the panel's mouse-up hook re-arms.
            selectionSettleTask?.cancel()
            selectionSettleTask = nil
            return
        }
        restartSelectionSettleTask()
    }

    /// Sets (or clears) the selection observer on both panes. The Recognized
    /// pane is the trigger surface; the Translation pane is observed solely so
    /// a selection there dismisses an active card. With `selection: nil` no
    /// delegate is wired at all — construction identical to a pre-selection
    /// build (FR-8/AC-8).
    @MainActor
    private func wireSelectionTrigger() {
        let delegate: NSTextViewDelegate? = currentSelectionHooks != nil ? self : nil
        sourceTextView?.delegate = delegate
        translationTextView?.delegate = delegate
    }

    /// The current Recognized-pane selection, raw (normalization happens at the
    /// decision points so the dedupe key and the request span can never drift).
    @MainActor
    private func recognizedSelection() -> String {
        guard let textView = sourceTextView else { return "" }
        let range = textView.selectedRange()
        guard range.length > 0 else { return "" }
        return (textView.string as NSString).substring(with: range)
    }

    /// The panel-level mouse-up hook — the reliable end-of-drag trigger
    /// (Fig. F2): a non-empty Recognized selection (re)arms the settle task.
    @MainActor
    private func handleLeftMouseUp() {
        guard currentSelectionHooks != nil else { return }
        guard !recognizedSelection().isEmpty else { return }
        restartSelectionSettleTask()
    }

    /// (Re)arms the 300 ms settle task: the lookup fires only after a quiet
    /// window with no further selection changes (`SelectionPolicy.settleDebounce`).
    @MainActor
    private func restartSelectionSettleTask() {
        selectionSettleTask?.cancel()
        selectionSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: SelectionPolicy.settleDebounce)
            guard !Task.isCancelled else { return }
            self?.selectionSettleDidFire()
        }
    }

    /// The settle task elapsed — re-check the world *now* (the mouse may be
    /// down again, the selection collapsed, or the span already answered) and
    /// fire if it all still holds.
    @MainActor
    private func selectionSettleDidFire() {
        selectionSettleTask = nil
        guard currentSelectionHooks != nil else { return }
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return } // mouse down again
        let span = SpanNormalizer.normalize(recognizedSelection())
        guard Self.shouldFireSelection(
            normalizedSpan: span, lastFired: lastFiredSpan, slotVisible: selectionCard != nil
        ) else { return }
        fireSelection(span: span)
    }

    /// FIRE (Fig. F2): supersede any in-flight lookup, mount the skeleton
    /// (pre-sized by the span's mode), grow the panel, and launch the lookup
    /// through the coordinator's hook. `span` is already normalized.
    @MainActor
    private func fireSelection(span: String) {
        guard let hooks = currentSelectionHooks else { return }
        selectionUIGeneration += 1
        let generation = selectionUIGeneration
        selectionTask?.cancel()
        lastFiredSpan = span
        mountSelectionCard(.loading(mode: SelectionMode.mode(for: span)), span: span)
        selectionTask = Task { @MainActor [weak self] in
            let outcome = await hooks.translate(span)
            self?.applySelectionOutcome(outcome, span: span, ifCurrent: generation)
        }
    }

    /// Applies a lookup outcome only while its fire-time generation is still
    /// current — the `renderPhoneticForTests`-style staleness guard (AC-7).
    /// Every outcome maps to exactly one card state (Fig. F5); `.superseded`
    /// renders nothing — a newer request owns the slot.
    @MainActor
    private func applySelectionOutcome(_ outcome: SelectionLookupOutcome, span: String, ifCurrent generation: Int) {
        guard selectionUIGeneration == generation else { return }
        switch outcome {
        case .success(let result):
            switch result.output {
            case .card(let card):
                mountSelectionCard(.dictionary(card), span: span)
            case .plain(let translation):
                mountSelectionCard(.plain(translation: translation, degraded: !result.contextUsed), span: span)
            }
        case .failure:
            mountSelectionCard(.error, span: span) // quiet inline row — never a dialog
        case .superseded:
            break
        }
    }

    // MARK: - Contextual selection — card slot + panel growth (TECH §F-4)

    /// Mounts (or re-renders) the card in the fixed slot after the Recognized
    /// section and sizes the slot + window for the new state. The slot is
    /// constructed on the first fire only — before that, nothing exists (FR-8).
    @MainActor
    private func mountSelectionCard(_ state: SelectionCardView.State, span: String) {
        guard let stack = resultStack, let sourceSection = sourceSectionView else { return }
        let card: SelectionCardView
        if let mounted = selectionCard {
            card = mounted
        } else {
            card = SelectionCardView()
            card.onDismiss = { [weak self] in self?.dismissSelectionCard() }
            stack.addArrangedSubview(card)
            stack.setCustomSpacing(Layout.cardSlotSpacing, after: sourceSection)
            card.widthAnchor.constraint(
                equalTo: stack.widthAnchor,
                constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
            ).isActive = true
            selectionCard = card
            frameBeforeSelectionGrowth = panel?.frame
        }
        card.render(state, span: span)
        setSelectionSlotHeight(
            SelectionCardView.fittingHeight(for: state, span: span, width: selectionSlotWidth)
        )
    }

    /// The width the mounted card gets: panel content width minus the result
    /// stack's side insets (the 440 pt panel default when nothing is laid out yet).
    @MainActor
    private var selectionSlotWidth: CGFloat {
        let contentWidth = panel?.contentView?.bounds.width ?? 0
        let insets = resultStack.map { $0.edgeInsets.left + $0.edgeInsets.right } ?? 32
        return (contentWidth > 0 ? contentWidth : 440) - insets
    }

    /// Pins the slot to `height` (≤ the 200 pt cap) and grows the window to
    /// absorb exactly Δ = slot + spacing (Fig. F4): top edge fixed, growth
    /// downward, shifted up by any `visibleFrame` shortfall so the card never
    /// clips offscreen. Recomputed from the pre-growth frame so a re-measure
    /// (skeleton → content) adjusts only on a real difference. Growth animates
    /// 180 ms ease-out; instant under Reduce Motion (DESIGN §02).
    @MainActor
    private func setSelectionSlotHeight(_ height: CGFloat) {
        let clamped = ceil(min(height, Layout.maxCardSlotHeight))
        if let constraint = selectionSlotHeightConstraint {
            constraint.constant = clamped
        } else if let card = selectionCard {
            let constraint = card.heightAnchor.constraint(equalToConstant: clamped)
            constraint.isActive = true
            selectionSlotHeightConstraint = constraint
        }
        guard let panel, let base = frameBeforeSelectionGrowth else { return }
        let delta = clamped + Layout.cardSlotSpacing
        var frame = base
        frame.size.height += delta
        frame.origin.y -= delta
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.y += max(0, visible.minY - frame.minY) // never clip offscreen
        }
        guard frame != panel.frame else { return }
        applyPanelFrame(frame, animated: !isReduceMotion)
    }

    /// Applies a window frame — 180 ms ease-out when animated (DESIGN §02),
    /// synchronous otherwise (shrink, Reduce Motion, headless tests).
    @MainActor
    private func applyPanelFrame(_ frame: NSRect, animated: Bool) {
        guard let panel else { return }
        guard animated, panel.isVisible else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.cardGrowDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Reduce Motion, injectable for tests (headless growth must be synchronous
    /// — the window animator lands frames asynchronously).
    var reduceMotionForTests: Bool?
    private var isReduceMotion: Bool {
        reduceMotionForTests ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Contextual selection — dismissal, one sink (TECH §F-6)

    /// The single dismissal sink, funnel for all six triggers (Esc, ✕, outside
    /// click, selection collapse, retranslate, new capture/error/close):
    /// cancels the settle + lookup tasks, supersedes any late outcome via the
    /// generation bump, unmounts the slot, and restores the pre-growth frame
    /// (shrink is always instant — DESIGN §02). Idempotent: safe to call from
    /// every teardown path, twice. Internal — doubles as a test seam.
    @MainActor
    func dismissSelectionCard() {
        selectionSettleTask?.cancel()
        selectionSettleTask = nil
        selectionTask?.cancel()
        selectionTask = nil
        selectionUIGeneration += 1
        lastFiredSpan = nil
        guard let card = selectionCard else { return }
        selectionSlotHeightConstraint = nil
        if let stack = card.superview as? NSStackView { stack.removeArrangedSubview(card) }
        card.removeFromSuperview()
        selectionCard = nil
        if let base = frameBeforeSelectionGrowth {
            applyPanelFrame(base, animated: false)
        }
        frameBeforeSelectionGrowth = nil
    }

    // MARK: - Selection test seams (mirroring the read-aloud seams)

    @MainActor var panelForTests: NSPanel? { panel }
    @MainActor var selectionCardForTests: SelectionCardView? { selectionCard }
    @MainActor var sourceTextViewForTests: NSTextView? { sourceTextView }
    @MainActor var isSelectionLookupInFlightForTests: Bool { selectionTask != nil }
    @MainActor var selectionUIGenerationForTests: Int { selectionUIGeneration }

    /// Drives the FIRE path directly (bypassing the 300 ms settle), normalizing
    /// and gating exactly like the settle path — inert without hooks, exactly
    /// as production is (FR-8).
    @MainActor func fireSelectionForTests(span: String) {
        guard currentSelectionHooks != nil else { return }
        let normalized = SpanNormalizer.normalize(span)
        guard Self.shouldFireSelection(
            normalizedSpan: normalized, lastFired: lastFiredSpan, slotVisible: selectionCard != nil
        ) else { return }
        fireSelection(span: normalized)
    }

    /// Delivers a lookup outcome through the same generation-guarded apply the
    /// production task uses (the `renderPhoneticForTests` pattern).
    @MainActor func applySelectionOutcomeForTests(
        _ outcome: SelectionLookupOutcome, span: String, generation: Int
    ) {
        applySelectionOutcome(outcome, span: span, ifCurrent: generation)
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

    /// One result pane as a vertical sub-stack: `[caption, text, phonetic]` with
    /// tight internal spacing (2 after the caption, 4 elsewhere) and every child
    /// pinned to the sub-stack's width so captions, text, and the phonetic line all
    /// span the pane. Grouping the pane lets a hidden phonetic line collapse inside
    /// it without touching the gap between panes.
    @MainActor
    private func paneStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let caption = views.first { stack.setCustomSpacing(2, after: caption) }
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
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
