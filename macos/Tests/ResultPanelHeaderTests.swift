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
}
