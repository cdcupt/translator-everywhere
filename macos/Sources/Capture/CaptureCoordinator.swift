import AppKit
import Foundation

/// The capture state machine (TECH §8.2).
///
/// Sequences `PermissionService` → `RegionCapturer` → `OCRService` and shows the
/// result in `ResultPanel`. An `actor` so the capture/OCR path runs off the main
/// actor; only UI mutation hops to `@MainActor`. Saving to the notebook is
/// opt-in — the panel surfaces a Save button that calls back into `save`.
actor CaptureCoordinator {

    private let permission: PermissionService
    private let capturer: RegionCapturer
    private let ocr: OCRService
    /// The result surface, behind the `ResultPresenting` seam so the present path
    /// (which pair the bar is handed, the threaded save codes) is unit-testable
    /// with a spy. `ResultPanel` is the production conformer.
    private let resultPanel: any ResultPresenting
    /// Non-secret preferences — the source of the active From/To pair
    /// (`lastUsedPair`), the secondary flip target, and the recent-targets list.
    private let settings: SettingsStore
    /// The single orchestrator (detect → guard → resolve → translate → fallback).
    /// An existential so the generation-token race can be unit-tested with a stub.
    private let service: any Translating
    /// The notebook a capture can be saved to *on demand*. Saving is opt-in: the
    /// result panel offers a "Save to Notebook" button (⌘S) that calls `save`.
    /// Optional so the capture path still works if the store failed to open at
    /// launch (the panel just won't show the Save button).
    private let notebook: NotebookStore?

    /// The last captured/entered source text, cached so `retranslate` can re-run
    /// the pipeline on the same source when the user changes the To language.
    /// `nil` until the first successful capture.
    private var lastCapture: String?

    /// Monotonic request token. `captureAndTranslate` / `retranslate` bump it and
    /// capture the value; when a translation returns, a token mismatch means a
    /// newer request started, so the stale result is dropped — no out-of-order UI
    /// update on rapid To changes (TECH §5).
    private var generation = 0

    /// Monotonic selection-lookup token (TECH §F-3) — the mirror of `generation`
    /// for the panel's selection seam. `translateSelectionLatest` bumps it per
    /// lookup; a mismatch on return means a newer selection started (AC-7).
    private var selectionGeneration = 0

    init(
        permission: PermissionService = PermissionService(),
        capturer: RegionCapturer = RegionCapturer(),
        ocr: OCRService = OCRService(),
        settings: SettingsStore = SettingsStore(),
        service: (any Translating)? = nil,
        resultPanel: any ResultPresenting,
        notebook: NotebookStore? = nil
    ) {
        self.permission = permission
        self.capturer = capturer
        self.ocr = ocr
        self.settings = settings
        self.service = service ?? TranslationService(settings: settings)
        self.resultPanel = resultPanel
        self.notebook = notebook
    }

    /// Runs one capture→OCR→show cycle. Safe to call repeatedly; the `actor`
    /// serializes overlapping hotkey presses.
    func captureAndTranslate() async {
        // 1. Permission gate — never invoke screencapture without access (§8.6b).
        guard permission.isGranted else {
            permission.requestAccess()
            await presentPermissionNeeded()
            return
        }

        // 2. Interactive region capture (off-main). nil = user cancelled (Esc).
        let imageURL: URL?
        do {
            imageURL = try await capturer.captureRegion()
        } catch {
            await present(title: "Capture failed", body: error.localizedDescription)
            return
        }
        guard let imageURL else {
            // Cancel: silently return to idle (DESIGN §1).
            return
        }
        // The PNG is transient — discard it whatever happens next.
        defer { try? FileManager.default.removeItem(at: imageURL) }

        // Show the panel instantly in a loading state — OCR + the (now
        // network-bound) translation that follow no longer leave the user staring
        // at nothing. The recognized text, then the translation, fill this in place.
        await presentTranslating(source: nil)

        // 3. On-device OCR.
        let recognized: String
        do {
            recognized = try await ocr.recognizeText(in: imageURL)
        } catch {
            await present(title: "Couldn’t read text", body: error.localizedDescription)
            return
        }

        let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await present(title: "No text found",
                          body: "Nothing recognizable was in the selection. Try again.")
            return
        }

        // Cache the source so a To-language change can re-run on it (`retranslate`).
        lastCapture = trimmed

        // OCR landed — surface the recognized text immediately (still "Translating…")
        // so the user sees what was read while the translation is in flight.
        await presentTranslating(source: trimmed)

        // 4. Translate via `TranslationService` (detect → guard → resolve →
        //    translate → AI-fallback), reading the active pair from settings.
        await runTranslation(text: trimmed, pair: settings.lastUsedPair)
    }

    /// Re-runs translation on the last captured text for a newly chosen `pair`
    /// (the language bar's To/⇄ change — slice 7's picker calls this via the
    /// `onRetranslate` closure). Persists the new pair, then drives the same
    /// generation-guarded path as a capture. No-op until something is captured.
    func retranslate(pair: LanguagePair) async {
        guard let text = lastCapture else { return }
        settings.lastUsedPair = pair
        await runTranslation(text: text, pair: pair)
    }

    /// The shared translate → present path for both capture and retranslate.
    /// Guards the result with the generation token: a result from a superseded
    /// request is dropped silently (no UI update); a current success copies +
    /// presents and records the recent target; a current failure shows an error.
    /// Internal so the present composition (effective-target display + threaded
    /// save codes) is unit-testable without driving capture/OCR.
    func runTranslation(text: String, pair: LanguagePair) async {
        switch await translateLatest(text: text, pair: pair) {
        case .superseded:
            return
        case let .failure(error):
            await presentError(title: "Translation failed", message: error.localizedDescription)
        case let .success(result):
            settings.recordRecentTarget(pair.to)
            await present(result: result, source: text, pair: pair)
        }
    }

    /// The outcome of a generation-guarded translate.
    enum TranslateOutcome {
        case success(TranslationResult)
        case failure(Error)
        /// A newer request started before this one's result returned — drop it.
        case superseded
    }

    /// Bumps the generation token, runs the service on the actor, and reports
    /// whether this call is still the newest when its result returns. Internal so
    /// the generation-token race is unit-testable without driving capture/OCR/UI.
    func translateLatest(text: String, pair: LanguagePair) async -> TranslateOutcome {
        generation &+= 1
        let token = generation
        do {
            let result = try await service.translate(text: text, pair: pair)
            guard token == generation else { return .superseded }
            return .success(result)
        } catch {
            guard token == generation else { return .superseded }
            return .failure(error)
        }
    }

    /// Runs one selection lookup under the TWO-token staleness guard (TECH §F-3):
    /// bumps `selectionGeneration` and captures the MAIN `generation`, then
    /// requires BOTH unchanged when the service returns — a newer selection
    /// (AC-7) or a capture/retranslate that changed the content underneath
    /// (FR-6) makes the result `.superseded`. Error taxonomy is preserved for
    /// the panel: `CancellationError` (the panel cancelled the lookup task)
    /// maps to `.superseded`; any other throw surfaces as `.failure` so the
    /// card can render the quiet error row. Internal so the race is
    /// unit-testable without driving capture/OCR/UI.
    func translateSelectionLatest(
        span: String, context: String, pair: LanguagePair
    ) async -> SelectionLookupOutcome {
        selectionGeneration &+= 1
        let token = selectionGeneration
        let mainToken = generation
        do {
            let result = try await service.translateSelection(span: span, context: context, pair: pair)
            guard token == selectionGeneration, mainToken == generation else { return .superseded }
            return .success(result)
        } catch is CancellationError {
            return .superseded
        } catch {
            guard token == selectionGeneration, mainToken == generation else { return .superseded }
            return .failure(error)
        }
    }

    /// Persists the capture to the notebook when the user opts in via the panel's
    /// Save button. Threads the resolved From/To BCP-47 codes the orchestrator
    /// derived into `srcLang`/`tgtLang`. Returns whether the save succeeded so the
    /// panel only claims "★ Saved" when it really did. Never throws to the caller
    /// — a notebook write failure surfaces as an inline retry on the panel, not a
    /// crash. The read of `notebook` stays on this actor; only the `@MainActor`
    /// store mutation hops to the main actor.
    func save(
        source: String,
        translation: String,
        from: String,
        to: String,
        kind: EngineKind
    ) async -> Bool {
        guard let notebook else { return false }
        do {
            try await MainActor.run {
                try notebook.add(
                    source: source, translation: translation, from: from, to: to, engine: kind
                )
            }
            return true
        } catch {
            NSLog("[TE] Notebook save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Copies the translation, builds the opt-in Save + retranslate closures, and
    /// presents the result. The pair handed to the panel is the *effective* pair —
    /// the original From with `result.effectiveTo` as To — so the bar shows the
    /// real target (a flipped Chinese→English capture reads "To: English", not
    /// "中文") and a ⇄ swap composes EN→ZH rather than a degenerate ZH→ZH. The
    /// notebook `srcLang`/`tgtLang` use the same authoritative codes: the source is
    /// the explicit From or the detected language (`"auto"` when neither), the
    /// target is `result.effectiveTo`. The effective target is read straight from
    /// the result (computed by the service before the translate await), never
    /// recomputed here post-await, so a Preferences change between translate and
    /// present can't make the displayed/stored target disagree with what was
    /// actually translated (TOCTOU). Closures capture `self` weakly to avoid a
    /// panel→controller→closure→coordinator retain cycle.
    private func present(result: TranslationResult, source: String, pair: LanguagePair) async {
        let copied = await copyToPasteboard(result.translation)

        let effectiveTo = result.effectiveTo
        let displayPair = LanguagePair(from: pair.from, to: effectiveTo)
        let fromCode = pair.from?.code ?? result.detected.languageCode ?? "auto"
        let toCode = effectiveTo.code

        let onSave: (@MainActor () async -> Bool)? = notebook.map { _ in
            { [weak self] in
                guard let self else { return false }
                return await self.save(
                    source: source, translation: result.translation,
                    from: fromCode, to: toCode, kind: result.servedBy
                )
            }
        }

        let onRetranslate: @MainActor (LanguagePair) -> Void = { [weak self] newPair in
            guard let self else { return }
            Task { await self.retranslate(pair: newPair) }
        }

        // ONE SelectionHooks per present (TECH §F-3). The translate hook
        // pre-captures the recognized text as context and PINS the pair —
        // explicit From → detected language → Auto, with the effective target —
        // so every lookup on this result translates against what was actually
        // captured, whatever Preferences do meanwhile. The save hook wraps the
        // existing `save` with the same threaded codes; nil without a notebook,
        // so the card offers no Save control (mirroring `onSave`).
        let detectedFrom: Language?
        if case let .identified(language, _) = result.detected {
            detectedFrom = language
        } else {
            detectedFrom = nil
        }
        let selectionPair = LanguagePair(from: pair.from ?? detectedFrom, to: effectiveTo)
        let onSelectionSave: (@MainActor (String, String, EngineKind) async -> Bool)? = notebook.map { _ in
            { [weak self] span, translation, servedBy in
                guard let self else { return false }
                return await self.save(
                    source: span, translation: translation,
                    from: fromCode, to: toCode, kind: servedBy
                )
            }
        }
        let selection = SelectionHooks(
            translate: { [weak self] span in
                guard let self else { return .superseded }
                return await self.translateSelectionLatest(
                    span: span, context: source, pair: selectionPair
                )
            },
            save: onSelectionSave
        )

        await presentResult(
            result: result, source: source, pair: displayPair,
            copied: copied, onSave: onSave, onRetranslate: onRetranslate,
            selection: selection
        )
    }

    // MARK: - UI hops (main actor)

    /// Writes `text` to the general pasteboard. Returns whether the write
    /// succeeded so the panel only claims "Copied ✓" when it really did.
    @MainActor
    private func copyToPasteboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    @MainActor
    private func presentResult(
        result: TranslationResult,
        source: String,
        pair: LanguagePair,
        copied: Bool,
        onSave: (@MainActor () async -> Bool)?,
        onRetranslate: @escaping @MainActor (LanguagePair) -> Void,
        selection: SelectionHooks
    ) {
        // LSUIElement agents launch unfocused — grab focus before showing.
        NSApp.activate(ignoringOtherApps: true)
        // Forwards the full multi-language data path (pair / detected / via-Google
        // / retranslate). Slice 7 draws the language bar + picker that render it;
        // this slice wires the data so the build stays green ahead of that UI.
        resultPanel.showResult(
            translation: result.translation,
            source: source,
            badge: result.servedBy.badge,
            copied: copied,
            pair: pair,
            detected: result.detected,
            viaGoogleFallback: result.viaGoogleFallback,
            onSave: onSave,
            onRetranslate: onRetranslate,
            selection: selection
        )
    }

    /// Shows (or refreshes) the instant loading panel. The first call (`source:
    /// nil`, right after capture) makes the panel appear and grabs focus; the
    /// second (`source:` = recognized text, after OCR) fills the Recognized section
    /// in place. The real result later supersedes this via `presentResult`.
    @MainActor
    private func presentTranslating(source: String?) {
        // LSUIElement agents launch unfocused — grab focus before showing.
        NSApp.activate(ignoringOtherApps: true)
        resultPanel.showTranslating(source: source)
    }

    @MainActor
    private func presentError(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        resultPanel.showError(title: title, message: message)
    }

    @MainActor
    private func present(title: String, body: String) {
        // LSUIElement agents launch unfocused — grab focus before showing.
        NSApp.activate(ignoringOtherApps: true)
        resultPanel.show(title: title, body: body)
    }

    @MainActor
    private func presentPermissionNeeded() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
        Translator Everywhere needs Screen Recording access to capture a region. \
        Enable it in System Settings, then relaunch the app.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            permission.openSettings()
        }
    }
}
