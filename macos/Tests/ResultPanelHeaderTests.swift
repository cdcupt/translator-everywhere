import AppKit
import Testing
@testable import Translator_Everywhere

/// The result panel's engine badge + header chips (beta A9/A10). Drives the pure
/// badge-color helper and the real header-population path headlessly (no window)
/// and asserts FREE-vs-AI rendering plus the conditional "via Google" / "Copied ✓"
/// notes.
@MainActor
@Suite("ResultPanel — badge color + header chips")
struct ResultPanelHeaderTests {

    // A9 — the badge renders the AI engine in purple and FREE in blue.
    @Test("Badge color is purple for AI and blue for FREE")
    func badgeColor() {
        #expect(ResultPanel.badgeColor(for: "AI") == .systemPurple)
        #expect(ResultPanel.badgeColor(for: "FREE") == .systemBlue)
        #expect(ResultPanel.badgeColor(for: "AI") != ResultPanel.badgeColor(for: "FREE"))
    }

    // A10 — the "via Google" note renders only on an AI→Google fallback.
    @Test("\"via Google\" note appears only when viaGoogleFallback is true")
    func viaGoogleNote() {
        let panel = ResultPanel()
        #expect(headerLabels(panel, viaGoogleFallback: true).contains("via Google"))
        #expect(!headerLabels(panel, viaGoogleFallback: false).contains("via Google"))
    }

    // A10 (surface) — the "Copied ✓" affordance is conditional on a copy.
    @Test("\"Copied ✓\" appears only after a copy")
    func copiedChip() {
        let panel = ResultPanel()
        #expect(headerLabels(panel, copied: true).contains("Copied ✓"))
        #expect(!headerLabels(panel, copied: false).contains("Copied ✓"))
    }

    // Outside-click deselect — a click on a selectable text view (or its
    // scroller, so a scroll-drag keeps the selection) must NOT clear; a click on
    // any other chrome (caption, button, empty area) MUST clear.
    @Test("Clicking inside a text view keeps the selection")
    func keepSelectionOnTextHit() {
        #expect(ResultPanel.shouldClearSelection(forHit: NSTextView()) == false)
        #expect(ResultPanel.shouldClearSelection(forHit: NSScroller()) == false)
    }

    @Test("Clicking outside a text view clears the selection")
    func clearSelectionOnChromeHit() {
        #expect(ResultPanel.shouldClearSelection(forHit: NSView()) == true)
        #expect(ResultPanel.shouldClearSelection(forHit: NSTextField(labelWithString: "Recognized")) == true)
        #expect(ResultPanel.shouldClearSelection(forHit: nil) == true)
    }

    @Test("A subview of a text view still counts as inside the text")
    func textViewSubviewCountsAsInside() {
        let textView = NSTextView()
        let inner = NSView()
        textView.addSubview(inner)
        #expect(ResultPanel.shouldClearSelection(forHit: inner) == false)
    }

    /// Populates a fresh header stack via the panel's real builder and returns its
    /// top-level text chips. The badge text lives inside a nested container, so the
    /// top-level `NSTextField`s are exactly the "via Google" / "Copied ✓" notes.
    private func headerLabels(
        _ panel: ResultPanel, badge: String = "AI",
        copied: Bool = false, viaGoogleFallback: Bool = false
    ) -> [String] {
        let header = NSStackView()
        panel.populateHeader(header, badge: badge, copied: copied,
                             viaGoogleFallback: viaGoogleFallback, onSave: nil)
        return header.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    }
}

/// The contextual-selection card's headless render + measurement contract
/// (TECH §04 P-03 / P-04): all five `SelectionCardView.State` fills render, nil
/// dictionary rows are omitted entirely (never blank), degraded is a styling
/// flag (dashed border + gray chip + note), the error row offers "Try again",
/// and `fittingHeight` is capped at 200 pt with mode-sized skeleton reservation.
@MainActor
@Suite("SelectionCardView — state renders + fitting height")
struct SelectionCardViewTests {

    private static let fullCard = DictionaryCard(
        headword: "scored",
        translation: "攻入（进球）",
        partOfSpeech: "verb",
        sense: "“score”的过去式 — 此处指把球踢进球门",
        example: "Messi scored the final goal.",
        exampleTranslation: "梅西攻入了最后一球。"
    )

    // P-03 — the dictionary state renders every present row: span echo, mode
    // chip, translation, POS chip, sense, and the example pair.
    @Test("Dictionary state renders all present rows")
    func dictionaryRendersPresentRows() {
        let card = SelectionCardView()
        card.render(.dictionary(Self.fullCard), span: "scored")
        let texts = labelStrings(in: card)
        #expect(texts.contains("scored"))
        #expect(texts.contains("In context · AI"))
        #expect(texts.contains("攻入（进球）"))
        #expect(texts.contains("verb"))
        #expect(texts.contains("“score”的过去式 — 此处指把球踢进球门"))
        #expect(texts.contains("Messi scored the final goal."))
        #expect(texts.contains("梅西攻入了最后一球。"))
        #expect(card.hasDashedBorderForTests == false)
    }

    // P-03 — nil POS/sense/example rows are omitted entirely, never rendered
    // as blank rows (FR-3).
    @Test("Dictionary state omits nil rows entirely, not as blanks")
    func dictionaryOmitsNilRows() {
        let bare = DictionaryCard(
            headword: "攻入", translation: "to score (a goal)",
            partOfSpeech: nil, sense: nil, example: nil, exampleTranslation: nil
        )
        let card = SelectionCardView()
        card.render(.dictionary(bare), span: "攻入")
        let texts = labelStrings(in: card)
        #expect(texts.contains("攻入"))
        #expect(texts.contains("to score (a goal)"))
        #expect(!texts.contains("verb"))
        let hasBlankLabel = texts.contains { $0.isEmpty }
        #expect(!hasBlankLabel, "nil rows must be omitted, not blank")
        // Exactly span echo + mode chip + translation — no dictionary-row leftovers.
        #expect(texts.count == 3)
    }

    // P-03 — the long-span plain fill has no dictionary rows (FR-4).
    @Test("Plain state renders only the translation block")
    func plainHasNoDictionaryRows() {
        let card = SelectionCardView()
        card.render(.plain(translation: "梅西攻入了最后一球。", degraded: false), span: "Messi scored the final goal.")
        let texts = labelStrings(in: card)
        #expect(texts.contains("梅西攻入了最后一球。"))
        #expect(texts.contains("In context · AI"))
        let hasBlankLabel = texts.contains { $0.isEmpty }
        #expect(!hasBlankLabel)
        #expect(texts.count == 3, "span echo + chip + translation only — no dictionary rows")
        #expect(card.hasDashedBorderForTests == false)
    }

    // P-03 — degraded is a styling flag on the plain fill: dashed border,
    // "Context-free · Google" chip, and a one-line add-a-key note (FR-5).
    @Test("Degraded plain state shows dashed border, Google chip, and note")
    func degradedStyling() {
        let card = SelectionCardView()
        card.render(.plain(translation: "最终目标", degraded: true), span: "the final goal")
        let texts = labelStrings(in: card)
        #expect(card.hasDashedBorderForTests == true)
        #expect(texts.contains("Context-free · Google"))
        #expect(!texts.contains("In context · AI"))
        #expect(texts.filter { $0.contains("add an AI key") }.count == 1)
    }

    // P-03 — the error fill is a quiet inline row whose retry control reads
    // "Try again" and fires `onRetry`.
    @Test("Error state renders a quiet row with Try again")
    func errorHasTryAgain() {
        let card = SelectionCardView()
        var retried = 0
        card.onRetry = { retried += 1 }
        card.render(.error, span: "scored")
        #expect(labelStrings(in: card).contains { $0.contains("Couldn’t translate") })
        let retry = buttons(in: card).first { $0.title == "Try again" }
        #expect(retry != nil)
        retry?.performClick(nil)
        #expect(retried == 1)
    }

    // P-03 — the loading fill mounts skeleton bars (no content rows, no retry)
    // and labels the group as busy for VoiceOver.
    @Test("Loading state renders skeleton bars, no content rows")
    func loadingRendersSkeleton() {
        let card = SelectionCardView()
        card.render(.loading(mode: .wordPhrase), span: "scored")
        #expect(card.skeletonBarCountForTests > 0)
        #expect(buttons(in: card).allSatisfy { $0.title != "Try again" })
        #expect(card.accessibilityLabel() == "Translating selection…")
    }

    // P-04 — pathological content (2000-char translation, 500-char span) never
    // pushes `fittingHeight` past the 200 pt cap.
    @Test("fittingHeight never exceeds the 200 pt cap")
    func fittingHeightIsCapped() {
        let hugeTranslation = String(repeating: "字", count: 2000)
        let hugeSpan = String(repeating: "s", count: 500)

        let plain = SelectionCardView.fittingHeight(
            for: .plain(translation: hugeTranslation, degraded: false),
            span: hugeSpan, width: 408
        )
        #expect(plain > 0)
        #expect(plain <= 200)

        let pathological = DictionaryCard(
            headword: hugeSpan, translation: hugeTranslation,
            partOfSpeech: "verb", sense: hugeTranslation,
            example: hugeTranslation, exampleTranslation: hugeTranslation
        )
        let dictionary = SelectionCardView.fittingHeight(
            for: .dictionary(pathological), span: hugeSpan, width: 408
        )
        #expect(dictionary > 0)
        #expect(dictionary <= 200)
    }

    // Review-fix (AC-7 · TECH F-3 pattern) — the card is one reused instance;
    // a save still in flight when the user re-selects must never touch the
    // controls the re-render swapped in for the new span.
    @Test("A save landing after a re-render never marks the new card Saved")
    func staleSaveSuccessNeverMarksNewCardSaved() async {
        let card = SelectionCardView()
        var pending: [CheckedContinuation<Bool, Never>] = []
        card.onSave = { await withCheckedContinuation { pending.append($0) } }

        card.render(.dictionary(Self.fullCard), span: "scored")
        let staleButton = saveButton(in: card)
        staleButton?.performClick(nil) // save A in flight
        await spin { pending.count == 1 }

        // AC-7 re-selection: the same card re-renders for a different span.
        card.render(.plain(translation: "最终目标", degraded: false), span: "the final goal")
        let newButton = saveButton(in: card)
        #expect(newButton !== staleButton)

        pending[0].resume(returning: true) // the stale save lands late
        await card.saveTaskForTests?.value

        #expect(newButton?.title == "☆ Save ⌘S",
                "a stale save must never label the new selection as Saved")
        #expect(newButton?.isEnabled == true)
    }

    @Test("A stale failed save never re-enables the new card's in-flight save")
    func staleSaveFailureNeverReenablesNewCard() async {
        let card = SelectionCardView()
        var pending: [CheckedContinuation<Bool, Never>] = []
        card.onSave = { await withCheckedContinuation { pending.append($0) } }

        card.render(.dictionary(Self.fullCard), span: "scored")
        saveButton(in: card)?.performClick(nil) // save A in flight
        await spin { pending.count == 1 }

        card.render(.plain(translation: "最终目标", degraded: false), span: "the final goal")
        let newButton = saveButton(in: card)
        newButton?.performClick(nil) // save B in flight on the new card
        await spin { pending.count == 2 }
        #expect(newButton?.isEnabled == false)

        pending[0].resume(returning: false) // stale A fails — would re-enable unguarded
        pending[1].resume(returning: true)  // B lands
        await spin { newButton?.title == "★ Saved" }

        #expect(newButton?.title == "★ Saved")
        #expect(newButton?.isEnabled == false,
                "the stale save must not re-enable a button whose own save is in flight")
    }

    // Review-fix round 2 (AC-7 · TECH F-3) — what the generation guard actually
    // protects: `isSaving` is the reentrancy latch shared by every activation
    // path, and a stale completion must not reset it while the new card's own
    // save is in flight — unguarded, that reset re-arms `saveTapped` and a
    // second rapid activation double-fires `onSave` for the same selection.
    // The second activation is sent at the action level: a raw click would be
    // swallowed by the disabled button cell, which is incidental (the stale
    // completion only touches its own captured button), not the invariant
    // under test.
    @Test("A stale completion never re-arms the new card's in-flight save")
    func staleCompletionNeverRearmsInFlightSave() async {
        let card = SelectionCardView()
        var saveCalls = 0
        var pending: [CheckedContinuation<Bool, Never>] = []
        card.onSave = {
            saveCalls += 1
            return await withCheckedContinuation { pending.append($0) }
        }

        card.render(.dictionary(Self.fullCard), span: "scored")
        saveButton(in: card)?.performClick(nil) // save A in flight
        await spin { pending.count == 1 }
        let staleTask = card.saveTaskForTests // save B's click will overwrite the property

        card.render(.plain(translation: "最终目标", degraded: false), span: "the final goal")
        let newButton = saveButton(in: card)
        newButton?.performClick(nil) // save B in flight on the new card
        await spin { pending.count == 2 }

        pending[0].resume(returning: false) // stale A fails …
        await staleTask?.value              // … and its completion has fully run

        // Second rapid activation on the new card while B is genuinely in flight.
        if let newButton { _ = newButton.sendAction(newButton.action, to: newButton.target) }
        await spin { saveCalls > 2 } // give an illegitimate third save every chance to start
        #expect(saveCalls == 2,
                "a stale completion must never re-arm save — onSave would double-fire")

        pending[1].resume(returning: true) // B lands normally
        await spin { newButton?.title == "★ Saved" }
        #expect(newButton?.title == "★ Saved")
        for extra in pending.dropFirst(2) { extra.resume(returning: false) } // tidy a failing run
    }

    // Review-fix (F-8) — the announcement fires once per content render, from
    // the mounted card only; loading/error stay silent.
    @Test("A content render posts exactly one VoiceOver announcement")
    func contentRenderAnnouncesOnce() {
        var announced: [String] = []
        let original = SelectionCardView.announcementPoster
        defer { SelectionCardView.announcementPoster = original }
        SelectionCardView.announcementPoster = { _, text in announced.append(text) }

        let card = SelectionCardView()
        card.render(.loading(mode: .wordPhrase), span: "scored")
        #expect(announced.isEmpty)
        card.render(.dictionary(Self.fullCard), span: "scored")
        #expect(announced == ["scored — 攻入（进球）, verb"])
        card.render(.plain(translation: "最终目标", degraded: true), span: "goal")
        #expect(announced == ["scored — 攻入（进球）, verb", "goal — 最终目标"])
        card.render(.error, span: "goal")
        #expect(announced.count == 2)
    }

    // Review-fix (F-8) — measurement is side-effect-free: the fittingHeight
    // probe renders off-screen and must never post the announcement the real
    // mounted render owns.
    @Test("fittingHeight measurement posts no VoiceOver announcement")
    func fittingHeightIsAnnouncementFree() {
        var announcements = 0
        let original = SelectionCardView.announcementPoster
        defer { SelectionCardView.announcementPoster = original }
        SelectionCardView.announcementPoster = { _, _ in announcements += 1 }

        _ = SelectionCardView.fittingHeight(
            for: .dictionary(Self.fullCard), span: "scored", width: 408
        )
        _ = SelectionCardView.fittingHeight(
            for: .plain(translation: "最终目标", degraded: true), span: "goal", width: 408
        )
        #expect(announcements == 0)
    }

    // Review-fix (P-04 · DESIGN §02) — the 200 pt cap is a real visual clamp
    // on the mounted card, not just a number: forced into the capped frame,
    // pathological content resolves inside the card — nothing paints past the
    // rounded bounds, nothing scrolls.
    @Test("A mounted card forced to the capped height clamps content inside its bounds")
    func mountedCardClampsPathologicalContent() {
        let huge = String(repeating: "字", count: 2000)
        let state = SelectionCardView.State.plain(translation: huge, degraded: false)

        let card = SelectionCardView()
        card.render(state, span: "the final goal")
        let height = SelectionCardView.fittingHeight(
            for: state, span: "the final goal", width: 408
        )
        #expect(height == 200, "precondition: the cap must engage for this fixture")

        card.frame = NSRect(x: 0, y: 0, width: 408, height: height)
        card.layoutSubtreeIfNeeded()

        let escapees = overflowingViews(in: card)
        #expect(escapees.isEmpty, "content must be clamped inside the card: \(escapees)")
    }

    // P-04 — skeleton pre-sizing: a word/phrase lookup reserves the taller
    // full-card skeleton, a long span the short plain block.
    @Test("Loading skeleton reserves more height for wordPhrase than longSpan")
    func skeletonPreSizing() {
        let word = SelectionCardView.fittingHeight(
            for: .loading(mode: .wordPhrase), span: "scored", width: 408
        )
        let long = SelectionCardView.fittingHeight(
            for: .loading(mode: .longSpan), span: "Messi scored the final goal.", width: 408
        )
        #expect(word > long)
        #expect(long > 0)
    }

    /// Every `NSTextField` string in the card's subtree, in document order.
    private func labelStrings(in root: NSView) -> [String] {
        var strings: [String] = []
        func visit(_ view: NSView) {
            if let field = view as? NSTextField { strings.append(field.stringValue) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return strings
    }

    /// Every `NSButton` in the card's subtree, in document order.
    private func buttons(in root: NSView) -> [NSButton] {
        var found: [NSButton] = []
        func visit(_ view: NSView) {
            if let button = view as? NSButton { found.append(button) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    /// The card's Save control, found by its stable tooltip (the title swaps
    /// to "★ Saved" after a confirmed save).
    private func saveButton(in root: NSView) -> NSButton? {
        buttons(in: root).first { $0.toolTip == "Save selection to Notebook (⌘S)" }
    }

    /// Bounded main-actor drain (the KeySyncTests idiom): yields until the
    /// condition holds — no wall-clock sleeps.
    private func spin(_ condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 1000 { await Task.yield(); spins += 1 }
    }

    /// Descendants whose *visible* rect (their frame intersected with every
    /// masking ancestor) escapes the card's bounds — the headless notion of
    /// "paints outside the card".
    private func overflowingViews(in card: NSView) -> [String] {
        var escapees: [String] = []
        func visit(_ view: NSView) {
            for sub in view.subviews {
                var visible = view.convert(sub.frame, to: card)
                var ancestor: NSView? = view
                while let masking = ancestor, masking !== card {
                    if masking.layer?.masksToBounds == true, let holder = masking.superview {
                        visible = visible.intersection(holder.convert(masking.frame, to: card))
                    }
                    ancestor = masking.superview
                }
                if !visible.isEmpty,
                   !card.bounds.insetBy(dx: -0.5, dy: -0.5).contains(visible) {
                    escapees.append("\(type(of: sub)) \(NSStringFromRect(visible))")
                }
                visit(sub)
            }
        }
        visit(card)
        return escapees
    }
}

/// The panel-side selection lifecycle (slice S6 — TECH §02 F-2/F-4/F-6, §04):
/// the pure fire-decision helper, the whitelist's card entry, the card slot's
/// growth/shrink geometry, the generation-guarded render seam, the teardown
/// sinks, and the zero-footprint guarantee with `selection: nil`.
@MainActor
@Suite("ResultPanel — selection card slot lifecycle", .serialized)
struct ResultPanelSelectionTests {

    private static let fullCard = DictionaryCard(
        headword: "scored",
        translation: "攻入（进球）",
        partOfSpeech: "verb",
        sense: "“score”的过去式 — 此处指把球踢进球门",
        example: "Messi scored the final goal.",
        exampleTranslation: "梅西攻入了最后一球。"
    )

    /// Hooks whose lookup parks until cancelled — the "in flight" fixture.
    /// `Task.sleep` observes cancellation, so the dismissal sink's
    /// `selectionTask?.cancel()` is what resolves it (recorded via `onCancelled`).
    private func parkedHooks(onCancelled: (@MainActor () -> Void)? = nil) -> SelectionHooks {
        SelectionHooks(
            translate: { _ in
                do { try await Task.sleep(for: .seconds(300)) } catch { onCancelled?() }
                return .superseded
            },
            save: nil
        )
    }

    /// Presents a result body with `selection:` hooks and hands back the panel,
    /// with growth forced synchronous (headless tests can't await an animator).
    /// `onSave` mounts the header's "Save to Notebook" button (the ⌘S routing
    /// tests need both possible key-equivalent targets to exist).
    private func presentedPanel(
        selection: SelectionHooks?, onSave: (@MainActor () async -> Bool)? = nil
    ) -> ResultPanel {
        let panel = ResultPanel()
        panel.reduceMotionForTests = true
        panel.showResult(
            translation: "你好，世界", source: "Hello world", badge: "AI",
            copied: false, onSave: onSave, selection: selection
        )
        return panel
    }

    // P-01 (AC-5 · FR-6) — the shouldClearSelection ancestry walk gains the
    // card entry: hits inside a SelectionCardView subtree keep the selection
    // (and the card); every pre-existing row holds byte-identical.
    @Test("A hit inside the selection card keeps the selection; existing rows unchanged")
    func whitelistKeepsCardHits() throws {
        let card = SelectionCardView()
        card.render(.dictionary(Self.fullCard), span: "scored")
        #expect(ResultPanel.shouldClearSelection(forHit: card) == false)
        let descendant = try #require(anyLabel(in: card), "the rendered card must have text descendants")
        #expect(ResultPanel.shouldClearSelection(forHit: descendant) == false)

        // The pre-existing matrix, re-asserted verbatim.
        #expect(ResultPanel.shouldClearSelection(forHit: NSTextView()) == false)
        #expect(ResultPanel.shouldClearSelection(forHit: NSScroller()) == false)
        #expect(ResultPanel.shouldClearSelection(forHit: NSView()) == true)
        #expect(ResultPanel.shouldClearSelection(forHit: NSTextField(labelWithString: "Recognized")) == true)
        #expect(ResultPanel.shouldClearSelection(forHit: nil) == true)
    }

    // P-02 (FR-1) — the pure fire decision: empty/punctuation-only never fire,
    // an identical span with the slot visible is deduped, the same span fires
    // again after a dismissal, and a new span always fires.
    @Test("shouldFireSelection: empty never; identical+visible deduped; dismissed/new spans fire")
    func fireDecisionMatrix() {
        // Empty → never.
        #expect(!ResultPanel.shouldFireSelection(normalizedSpan: "", lastFired: nil, slotVisible: false))
        #expect(!ResultPanel.shouldFireSelection(normalizedSpan: "", lastFired: "scored", slotVisible: true))
        // Punctuation-only → no fire (DESIGN §06 — nothing to translate).
        #expect(!ResultPanel.shouldFireSelection(normalizedSpan: "…!?", lastFired: nil, slotVisible: false))
        // Identical span + slot visible → no re-fire (dedupe; the card already answers it).
        #expect(!ResultPanel.shouldFireSelection(normalizedSpan: "scored", lastFired: "scored", slotVisible: true))
        // Identical span + slot hidden → fire (the card was dismissed).
        #expect(ResultPanel.shouldFireSelection(normalizedSpan: "scored", lastFired: "scored", slotVisible: false))
        // New span → fire.
        #expect(ResultPanel.shouldFireSelection(normalizedSpan: "final goal", lastFired: "scored", slotVisible: true))
        #expect(ResultPanel.shouldFireSelection(normalizedSpan: "scored", lastFired: nil, slotVisible: false))
    }

    // P-05 (AC-5 · FR-6 · DESIGN §02) — mounting a card grows the window
    // downward only (top edge fixed, delta ≤ 200 pt); dismissal restores the
    // exact original frame.
    @Test("Mounting a card grows the panel downward only; dismissal restores the frame")
    func cardGrowthAndDismissalRestore() throws {
        let panel = presentedPanel(selection: SelectionHooks(translate: { _ in .superseded }, save: nil))
        let window = try #require(panel.panelForTests)
        let original = window.frame

        panel.fireSelectionForTests(span: "Hello")
        #expect(panel.selectionCardForTests != nil, "the fire must mount the card slot")
        let grown = window.frame
        #expect(abs(grown.maxY - original.maxY) < 0.5, "the top edge must stay fixed")
        #expect(grown.height > original.height, "the panel must grow to make room")
        #expect(grown.height - original.height <= 200, "growth stays within the slot cap")
        #expect(grown.minY < original.minY, "growth is downward only")

        panel.dismissSelectionCard()
        #expect(panel.selectionCardForTests == nil)
        #expect(window.frame == original, "dismissal restores the exact original frame")
    }

    // P-07 (AC-7) — a lookup outcome delivered after the UI generation moved
    // on is discarded via the guarded render seam (the renderPhoneticForTests
    // pattern); the current generation still renders.
    @Test("A stale outcome delivered after the generation bumps is discarded")
    func staleOutcomeDiscarded() throws {
        let panel = presentedPanel(selection: parkedHooks())

        panel.fireSelectionForTests(span: "scored")
        let staleGeneration = panel.selectionUIGenerationForTests

        panel.fireSelectionForTests(span: "final goal") // supersedes — bumps the generation
        let card = try #require(panel.selectionCardForTests)
        #expect(card.skeletonBarCountForTests > 0, "the newer lookup owns the slot (skeleton up)")

        let result = SelectionResult(output: .card(Self.fullCard), servedBy: .ai, contextUsed: true)
        panel.applySelectionOutcomeForTests(.success(result), span: "scored", generation: staleGeneration)
        #expect(card.skeletonBarCountForTests > 0, "a stale outcome must not render")
        #expect(!labelStrings(in: card).contains("攻入（进球）"))

        panel.applySelectionOutcomeForTests(
            .success(result), span: "final goal", generation: panel.selectionUIGenerationForTests
        )
        #expect(labelStrings(in: card).contains("攻入（进球）"), "the current generation renders")
    }

    // P-08 (AC-8 · FR-8) — with `selection: nil` (every pre-existing call
    // site's shape) no card exists anywhere, no delegate is wired, and the
    // fire path is unreachable: construction identical to v1.2.10.
    @Test("showResult with selection: nil builds no card and wires no delegate")
    func nilSelectionHasZeroFootprint() throws {
        let panel = ResultPanel()
        panel.showResult(translation: "出口", source: "Exit", badge: "FREE", copied: false)
        let content = try #require(panel.panelForTests?.contentView)
        #expect(selectionCards(in: content).isEmpty, "no SelectionCardView in the hierarchy")
        #expect(panel.sourceTextViewForTests?.delegate == nil, "no delegate side effects")

        // Even the fire seam is inert without hooks — no card can ever mount.
        panel.fireSelectionForTests(span: "Exit")
        #expect(panel.selectionCardForTests == nil)
        #expect(selectionCards(in: content).isEmpty)
    }

    /// The three teardown funnels I-13 walks in turn.
    enum TeardownSink: String, CaseIterable {
        case dropResultBody, setRetranslating, updateResult
    }

    // I-13 (AC-5 · FR-6) — with a card mounted and a lookup in flight, each
    // teardown funnel dismisses the card and cancels the settle/request task
    // before content changes (retranslate-dismisses-card and
    // new-capture-dismisses-card both funnel through here).
    @Test("Teardown sinks dismiss the card and cancel the in-flight lookup",
          arguments: TeardownSink.allCases)
    func teardownSinksDismissTheCard(sink: TeardownSink) async throws {
        var cancelled = false
        let panel = presentedPanel(selection: parkedHooks(onCancelled: { cancelled = true }))

        panel.fireSelectionForTests(span: "Hello")
        #expect(panel.selectionCardForTests != nil, "precondition: a card is mounted")
        #expect(panel.isSelectionLookupInFlightForTests, "precondition: a lookup is in flight")

        switch sink {
        case .dropResultBody:
            panel.dropResultBody()
        case .setRetranslating:
            panel.setRetranslating()
        case .updateResult:
            let en = try #require(LanguageCatalog.language(forCode: "en"))
            panel.updateResult(
                translation: "T", source: "S", badge: "AI", copied: false,
                pair: LanguagePair(from: nil, to: en), detected: .unavailable,
                viaGoogleFallback: false, onSave: nil, onRetranslate: nil
            )
        }

        #expect(panel.selectionCardForTests == nil, "\(sink.rawValue) must dismiss the card")
        #expect(panel.isSelectionLookupInFlightForTests == false,
                "\(sink.rawValue) must cancel the in-flight lookup")
        await spin { cancelled }
        #expect(cancelled, "\(sink.rawValue) must actually cancel the request task")
    }

    // P-06 (AC-6 · FR-7) — the roaming ⌘S: content states move the key
    // equivalent to the card's Save control; loading/error leave it on the
    // header (there is no card translation to save yet); the dismissal sink
    // reverts it. One shortcut, never two active targets.
    @Test("⌘S moves to the card on content render, stays on the header for loading/error, reverts on dismissal")
    func commandSRoutingSwapsAndReverts() throws {
        let hooks = SelectionHooks(
            translate: { _ in .superseded }, // outcomes injected via the render seam
            save: { _, _, _ in true }
        )
        let panel = presentedPanel(selection: hooks, onSave: { true })
        let content = try #require(panel.panelForTests?.contentView)
        let header = try #require(headerSaveButton(in: content))
        #expect(commandSHolders(in: content) == [header], "the header owns ⌘S before any card")

        // Loading: ⌘S stays on the header — mid-lookup still saves the whole capture.
        panel.fireSelectionForTests(span: "scored")
        let card = try #require(panel.selectionCardForTests)
        #expect(card.skeletonBarCountForTests > 0, "precondition: the loading fill is up")
        #expect(cardSaveButton(in: card) == nil, "the loading fill offers no Save control")
        #expect(commandSHolders(in: content) == [header], "loading leaves ⌘S on the header")

        // Content: the card's Save control takes ⌘S; the header button stays
        // visible but goes bare.
        let result = SelectionResult(output: .card(Self.fullCard), servedBy: .ai, contextUsed: true)
        panel.applySelectionOutcomeForTests(
            .success(result), span: "scored", generation: panel.selectionUIGenerationForTests
        )
        let cardSave = try #require(cardSaveButton(in: card), "a content state mounts the card's Save control")
        #expect(commandSHolders(in: content) == [cardSave], "a content state moves ⌘S to the card")
        #expect(header.superview != nil, "the header button stays visible + clickable")

        // Error: no Save control on the card — ⌘S is back on the header.
        panel.fireSelectionForTests(span: "final goal")
        panel.applySelectionOutcomeForTests(
            .failure(TranslationError.timedOut), span: "final goal",
            generation: panel.selectionUIGenerationForTests
        )
        #expect(cardSaveButton(in: card) == nil, "the error fill offers no Save control")
        #expect(commandSHolders(in: content) == [header], "the error state leaves ⌘S on the header")

        // Content again, then the dismissal sink reverts the key equivalent.
        panel.fireSelectionForTests(span: "goal")
        panel.applySelectionOutcomeForTests(
            .success(result), span: "goal", generation: panel.selectionUIGenerationForTests
        )
        #expect(commandSHolders(in: content).count == 1, "never two active ⌘S targets")
        #expect(commandSHolders(in: content).first !== header)

        panel.dismissSelectionCard()
        #expect(panel.selectionCardForTests == nil)
        #expect(commandSHolders(in: content) == [header], "dismissal reverts ⌘S to the header")
    }

    // I-14 (FR-1 · FR-6 · DESIGN §03) — a scripted `.failure(.timedOut)` lands
    // as the quiet inline error row (the result body stays up — no dialog),
    // and "Try again" re-fires the SAME span through the hooks exactly once
    // more, running the full lookup lifecycle again.
    @Test("Timed-out lookup renders the quiet error row; Try again re-fires the same span once")
    func timedOutRetryRefiresSameSpan() async throws {
        var requestedSpans: [String] = []
        let hooks = SelectionHooks(
            translate: { span in
                requestedSpans.append(span)
                return .failure(TranslationError.timedOut)
            },
            save: nil
        )
        let panel = presentedPanel(selection: hooks)

        panel.fireSelectionForTests(span: "scored")
        let card = try #require(panel.selectionCardForTests)
        await spin { buttons(in: card).contains { $0.title == "Try again" } }
        #expect(requestedSpans == ["scored"], "one lookup fired")
        #expect(labelStrings(in: card).contains { $0.contains("Couldn’t translate") },
                "the failure renders the quiet inline row")
        #expect(panel.sourceTextViewForTests != nil,
                "the result body is untouched — the error is a row in the card, not a dialog")

        let retry = try #require(buttons(in: card).first { $0.title == "Try again" })
        retry.performClick(nil)
        await spin { requestedSpans.count >= 2 }
        #expect(requestedSpans == ["scored", "scored"],
                "retry invokes translate exactly once more, with the same span")

        // The re-fire runs the full lifecycle: the scripted failure lands as
        // the quiet row again (and no extra lookup sneaks in).
        await spin { buttons(in: card).contains { $0.title == "Try again" } }
        #expect(requestedSpans.count == 2)
    }

    // LIVE-DEFECT regression (2026-07-10, feat/contextual-selection): in the
    // running app a mouse-made selection NEVER fired the lookup — no skeleton,
    // no card, no growth — while all 299 spy-driven tests were green, because
    // they all entered at `fireSelectionForTests` and skipped the trigger
    // chain. The dead link: `NSTextView.mouseDown` runs a mouse-tracking loop,
    // so (a) mid-drag selection changes are set with `stillSelecting: true`
    // and deliver NO `textViewDidChangeSelection` (a drag delivers ZERO
    // notifications end to end — verified live), (b) any notification that
    // does arrive (double-click word select) reads the button as still
    // pressed, which used to cancel the settle and stand down, and (c) the
    // matching leftMouseUp is dequeued INSIDE the tracking loop and never
    // passes through `KeyablePanel.sendEvent`, so the mouse-up "re-arm" hook
    // was dead code. These two tests drive the REAL chain — the live
    // presentation sequence and the real event/delegate wiring — not the fire
    // seam.

    // The drag/double-click event contract, end to end: a REAL leftMouseDown
    // dispatched through `KeyablePanel.sendEvent` into the REAL `NSTextView`,
    // whose tracking loop consumes a pre-posted matching mouse-up exactly as
    // live AppKit does (sendEvent never sees it), with the button held for the
    // whole dispatch. The selection must still fire the hooks' lookup and
    // mount the slot once the interaction ends.
    @Test("A mouse-made selection fires through the real event path (tracking loop eats the mouse-up)")
    func mouseSelectionFiresThroughRealEventPath() async throws {
        var requested: [String] = []
        let hooks = SelectionHooks(
            translate: { span in
                requested.append(span)
                return .superseded // outcome rendering is covered elsewhere
            },
            save: nil
        )

        // The REAL capture presentation sequence (CaptureCoordinator's order):
        // loading body, OCR fill, then the result supersedes it in place.
        let panel = ResultPanel()
        panel.reduceMotionForTests = true
        panel.showTranslating(source: nil)
        panel.showTranslating(source: "Messi scored the final goal.")
        panel.showResult(
            translation: "梅西攻入了最后一球。", source: "Messi scored the final goal.",
            badge: "AI", copied: false, selection: hooks
        )
        let window = try #require(panel.panelForTests)
        let sourceTV = try #require(panel.sourceTextViewForTests)
        #expect(sourceTV.delegate === panel,
                "the live present path must wire the selection trigger delegate")
        window.contentView?.layoutSubtreeIfNeeded()

        // Aim a double-click at the middle of "scored" in the Recognized pane.
        let charRange = (sourceTV.string as NSString).range(of: "scored")
        let layoutManager = try #require(sourceTV.layoutManager)
        let container = try #require(sourceTV.textContainer)
        layoutManager.ensureLayout(for: container)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        glyphRect.origin.x += sourceTV.textContainerOrigin.x
        glyphRect.origin.y += sourceTV.textContainerOrigin.y
        let pointInWindow = sourceTV.convert(NSPoint(x: glyphRect.midX, y: glyphRect.midY), to: nil)

        func mouse(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: pointInWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 2, pressure: 1
            )
        }
        let down = try #require(mouse(.leftMouseDown))
        let up = try #require(mouse(.leftMouseUp))

        // Live ordering: the button is physically down for the whole dispatch
        // (any selection-change notification inside it reads pressed=1), and
        // the up is consumed by the text view's tracking loop — posted to the
        // event queue, never routed through sendEvent.
        panel.pressedMouseButtonsForTests = 1
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        panel.pressedMouseButtonsForTests = 0 // dispatch over ⇒ button released

        // The REAL tracking loop owns the resulting range (a queue-posted up can
        // resolve a shifted point and extend word-wise) — the contract under
        // test is selection → fire, so the expected span is whatever the real
        // machinery selected, anchored on the double-clicked word.
        let selected = (sourceTV.string as NSString).substring(with: sourceTV.selectedRange())
        #expect(selected.hasPrefix("scored"),
                "the real double-click dispatch selects starting at the clicked word")
        let expected = SpanNormalizer.normalize(selected)
        try #require(!expected.isEmpty, "precondition: the dispatch produced a selection")

        await settleSpin { !requested.isEmpty }
        #expect(requested == [expected],
                "the settled mouse selection must fire exactly one lookup through the hooks")
        #expect(panel.selectionCardForTests != nil, "the card slot must mount")
    }

    // The losing double-click ordering in isolation, via the REAL delegate
    // notification (no fire-seam shortcut): the word-select notification
    // arrives while the button is still pressed; the release produces no
    // further notification and no panel-level mouse-up. The lookup must still
    // fire once the button is up.
    @Test("A selection change delivered while the button is held still fires after the release")
    func heldButtonSelectionFiresAfterRelease() async throws {
        var requested: [String] = []
        let hooks = SelectionHooks(
            translate: { span in
                requested.append(span)
                return .superseded
            },
            save: nil
        )
        let panel = ResultPanel()
        panel.reduceMotionForTests = true
        panel.showTranslating(source: nil)
        panel.showTranslating(source: "Messi scored the final goal.")
        panel.showResult(
            translation: "梅西攻入了最后一球。", source: "Messi scored the final goal.",
            badge: "AI", copied: false, selection: hooks
        )
        let sourceTV = try #require(panel.sourceTextViewForTests)

        // Second click of a double-click: the word is selected while the
        // button is held — setSelectedRange drives the REAL AppKit delegate
        // notification into the panel.
        panel.pressedMouseButtonsForTests = 1
        sourceTV.setSelectedRange((sourceTV.string as NSString).range(of: "scored"))

        // The release: consumed by the tracking loop live — no sendEvent
        // mouse-up, no further selection-change notification.
        panel.pressedMouseButtonsForTests = 0

        await settleSpin { !requested.isEmpty }
        #expect(requested == ["scored"],
                "the selection must fire once the button is released")
        #expect(panel.selectionCardForTests != nil, "the card slot must mount")
    }

    // MUTATION-PIN (QA round, mutation A — the down-return hook): a DRAG-made
    // selection delivers ZERO selection-change notifications end to end
    // (verified live — every mid-drag set uses `stillSelecting`), and the
    // mouse-up is consumed by the tracking loop, so the RETURN of the
    // dispatched mouse-down is the ONLY signal that can arm the settle.
    // `mouseSelectionFiresThroughRealEventPath` cannot pin that hook: its
    // synthetic double-click delivers one final notification a live drag never
    // does, and the held-button re-arm masks a removed hook. Here the delegate
    // is detached for exactly the dispatch window, reproducing the live
    // zero-notification drag headlessly — the down-return hook (which reads
    // the text view directly, not the delegate) is all that remains.
    @Test("A tracking-loop selection delivering no notification still fires via the down-return hook")
    func noNotificationSelectionFiresViaDownReturnHook() async throws {
        var requested: [String] = []
        let hooks = SelectionHooks(
            translate: { span in
                requested.append(span)
                return .superseded
            },
            save: nil
        )
        let panel = ResultPanel()
        panel.reduceMotionForTests = true
        panel.showTranslating(source: nil)
        panel.showTranslating(source: "Messi scored the final goal.")
        panel.showResult(
            translation: "梅西攻入了最后一球。", source: "Messi scored the final goal.",
            badge: "AI", copied: false, selection: hooks
        )
        let window = try #require(panel.panelForTests)
        let sourceTV = try #require(panel.sourceTextViewForTests)
        #expect(sourceTV.delegate === panel,
                "precondition: the live present path wires the selection trigger delegate")
        window.contentView?.layoutSubtreeIfNeeded()

        // Aim a double-click at the middle of "scored" in the Recognized pane.
        let charRange = (sourceTV.string as NSString).range(of: "scored")
        let layoutManager = try #require(sourceTV.layoutManager)
        let container = try #require(sourceTV.textContainer)
        layoutManager.ensureLayout(for: container)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        glyphRect.origin.x += sourceTV.textContainerOrigin.x
        glyphRect.origin.y += sourceTV.textContainerOrigin.y
        let pointInWindow = sourceTV.convert(NSPoint(x: glyphRect.midX, y: glyphRect.midY), to: nil)

        func mouse(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: pointInWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 2, pressure: 1
            )
        }
        let down = try #require(mouse(.leftMouseDown))
        let up = try #require(mouse(.leftMouseUp))

        // The live drag contract: no notification for the whole interaction.
        // Detaching the delegate for the dispatch window cancels the synthetic
        // dispatch's one spurious notification; the button stays pressed for
        // the whole dispatch and the up is consumed inside the tracking loop.
        let originalDelegate = sourceTV.delegate
        sourceTV.delegate = nil
        panel.pressedMouseButtonsForTests = 1
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        panel.pressedMouseButtonsForTests = 0 // dispatch over ⇒ button released
        sourceTV.delegate = originalDelegate  // interaction over — live wiring restored

        let selected = (sourceTV.string as NSString).substring(with: sourceTV.selectedRange())
        let expected = SpanNormalizer.normalize(selected)
        try #require(!expected.isEmpty, "precondition: the dispatch produced a selection")

        await settleSpin { !requested.isEmpty }
        #expect(requested == [expected],
                "with zero notifications, only the down-return hook can arm the settle — it must fire")
        #expect(panel.selectionCardForTests != nil, "the card slot must mount")
    }

    // MUTATION-PIN (QA round, mutation C — the poll-until-release branch):
    // when the 300 ms debounce elapses while the button is STILL down (a slow
    // drag / long double-click hold), `selectionSettleDidFire` must re-arm and
    // poll for the release rather than dying — the matching mouse-up may never
    // reach `sendEvent`, so nothing else will ever retry.
    // `heldButtonSelectionFiresAfterRelease` cannot pin that branch: it
    // releases the seam synchronously, long before the debounce elapses, so
    // the fire-time button check never reads pressed. Here the seam is
    // released only AFTER the settle has verifiably elapsed while pressed.
    @Test("A settle that elapses while the button is still down polls until the release, then fires")
    func settleElapsingWhileHeldPollsUntilRelease() async throws {
        var requested: [String] = []
        let hooks = SelectionHooks(
            translate: { span in
                requested.append(span)
                return .superseded
            },
            save: nil
        )
        let panel = ResultPanel()
        panel.reduceMotionForTests = true
        panel.showTranslating(source: nil)
        panel.showTranslating(source: "Messi scored the final goal.")
        panel.showResult(
            translation: "梅西攻入了最后一球。", source: "Messi scored the final goal.",
            badge: "AI", copied: false, selection: hooks
        )
        let sourceTV = try #require(panel.sourceTextViewForTests)

        // The word-select notification arrives while the button is held (the
        // real AppKit delegate path), arming the settle.
        panel.pressedMouseButtonsForTests = 1
        sourceTV.setSelectedRange((sourceTV.string as NSString).range(of: "scored"))

        // Hold PAST the debounce (300 ms — 3x margin): the settle elapses
        // while the seam still reads pressed, forcing the fire-time button
        // check. FR-1 holds throughout — nothing may fire while held.
        await settleSpin(timeout: .milliseconds(900)) { !requested.isEmpty }
        #expect(requested.isEmpty, "FR-1: no lookup may fire while the button is down")

        // Only now release. No mouse-up reaches sendEvent and no further
        // notification arrives (the tracking loop consumed both live) — the
        // re-armed poll is the only path left to complete the fire.
        panel.pressedMouseButtonsForTests = 0
        await settleSpin { !requested.isEmpty }
        #expect(requested == ["scored"],
                "the elapsed-while-held settle must poll until the release, then fire exactly once")
        #expect(panel.selectionCardForTests != nil, "the card slot must mount")
    }

    // MARK: - Helpers

    /// Wall-clock-capable drain for the 300 ms settle debounce (the yield-based
    /// `spin` burns its budget in microseconds, long before a real debounce).
    private func settleSpin(
        timeout: Duration = .seconds(3), _ condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Every `NSTextField` string in the subtree, in document order.
    private func labelStrings(in root: NSView) -> [String] {
        var strings: [String] = []
        func visit(_ view: NSView) {
            if let field = view as? NSTextField { strings.append(field.stringValue) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return strings
    }

    /// Every `NSButton` in the subtree, in document order.
    private func buttons(in root: NSView) -> [NSButton] {
        var found: [NSButton] = []
        func visit(_ view: NSView) {
            if let button = view as? NSButton { found.append(button) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    /// The buttons currently holding the ⌘S key equivalent — the P-06
    /// invariant is that exactly one visible button holds it at any moment.
    private func commandSHolders(in root: NSView) -> [NSButton] {
        buttons(in: root).filter {
            $0.keyEquivalent == "s" && $0.keyEquivalentModifierMask.contains(.command)
        }
    }

    /// The header's whole-capture Save button (stable title; the card's
    /// control carries a different tooltip).
    private func headerSaveButton(in root: NSView) -> NSButton? {
        buttons(in: root).first { $0.title == "Save to Notebook" }
    }

    /// The card's Save control, found by its stable tooltip (the title swaps
    /// to "★ Saved" after a confirmed save).
    private func cardSaveButton(in root: NSView) -> NSButton? {
        buttons(in: root).first { $0.toolTip == "Save selection to Notebook (⌘S)" }
    }

    /// Any text-field descendant of the card — a deep whitelist probe target.
    private func anyLabel(in root: NSView) -> NSTextField? {
        for view in root.subviews {
            if let field = view as? NSTextField { return field }
            if let found = anyLabel(in: view) { return found }
        }
        return nil
    }

    /// Every `SelectionCardView` in the subtree (P-08 asserts none exist).
    private func selectionCards(in root: NSView) -> [SelectionCardView] {
        var found: [SelectionCardView] = []
        func visit(_ view: NSView) {
            if let card = view as? SelectionCardView { found.append(card) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    /// Bounded main-actor drain (the KeySyncTests idiom): yields until the
    /// condition holds — no wall-clock sleeps.
    private func spin(_ condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 1000 { await Task.yield(); spins += 1 }
    }
}
