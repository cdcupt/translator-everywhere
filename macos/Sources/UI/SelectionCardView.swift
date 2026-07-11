import AppKit

/// The contextual-selection card mounted below the Recognized pane (TECH §02,
/// DESIGN §02). One view, four fills — loading skeleton, dictionary card,
/// plain block, quiet error row — where "degraded" is a styling flag on the
/// plain fill (dashed border, gray "Context-free · Google" chip, add-a-key
/// note), never a separate state. The card renders exactly what it is given:
/// card-vs-plain-vs-degraded is decided by the service, and the only mode use
/// here is pre-sizing the loading skeleton.
///
/// The owning panel sets `onDismiss`/`onRetry`/`onSave` before calling
/// `render(_:span:)`; a nil `onSave` (no notebook) means no Save control.
@MainActor
final class SelectionCardView: NSView {

    /// What the card is showing. Every `SelectionLookupOutcome` maps to exactly
    /// one of these (TECH Fig. F5); `plain` carries both the long-span block
    /// (`degraded: false`) and the Google-only variant (`degraded: true`).
    enum State: Equatable {
        case loading(mode: SelectionMode)
        case dictionary(DictionaryCard)
        case plain(translation: String, degraded: Bool)
        case error
    }

    /// The ✕ button / Esc funnel — the panel's single dismissal sink calls back
    /// through this.
    var onDismiss: (@MainActor () -> Void)?

    /// The error row's "Try again" — re-fires the same span.
    var onRetry: (@MainActor () -> Void)?

    /// Saves the card (span → source, card translation → translation) through
    /// the panel's hooks. `nil` ⇒ no Save control (AC-6: notebook unavailable).
    var onSave: (@MainActor () async -> Bool)?

    /// Card growth cap (DESIGN §02): the slot never exceeds this; internal
    /// content never scrolls — pathological content is clamped, not scrolled.
    static let maxHeight: CGFloat = 200

    // MARK: - Metrics (DESIGN §05 token table)

    private enum Metrics {
        static let cornerRadius: CGFloat = 9
        static let insetTop: CGFloat = 12       // top/bottom insets
        static let insetSide: CGFloat = 14      // side insets — card is subordinate to the panel's 16
        static let rowGap: CGFloat = 8
        static let spanEchoMaxWidth: CGFloat = 150
        static let translationMaxLines = 3      // like the IPA cap; long content belongs to plain mode
    }

    private let contentStack = NSStackView()

    /// Masks content to the rounded card when the panel clamps the frame to
    /// `maxHeight` (DESIGN §02: clamped, never scrolled). A separate view
    /// because `masksToBounds` on the card's own layer would clip its shadow.
    private let contentClipView = NSView()
    private let borderLayer = CAShapeLayer()

    /// Labels that wrap, re-measured against the current width in `layout()`
    /// (and by `fittingHeight`) so multi-line rows report true heights.
    private var wrappingLabels: [NSTextField] = []

    /// The loading fill's placeholder bars — never read by VoiceOver.
    private var skeletonBars: [NSView] = []

    private weak var saveButton: NSButton?
    private var isSaveKeyEquivalentActive = false
    private var isSaving = false

    /// Bumped on every `render` — the F-3-style staleness token for the card's
    /// own async save: this one view is reused across selections (TECH F-1), so
    /// a save resolving after a re-render belongs to a superseded card and must
    /// not touch the rebuilt controls (AC-7).
    private var renderGeneration = 0

    /// Set on `fittingHeight`'s throwaway probe: measurement must stay
    /// side-effect-free — the F-8 announcement belongs to the mounted card only.
    private var isMeasurementProbe = false

    /// The in-flight async-save task — internal so `@testable` tests can
    /// deterministically join a save that resolves after a re-render.
    private(set) var saveTaskForTests: Task<Void, Never>?

    /// The F-8 announcement sink — static and swappable so tests can pin both
    /// halves of the contract: the mounted card posts exactly once per content
    /// render, and the `fittingHeight` probe never posts. Production keeps the
    /// real NSAccessibility poster.
    static var announcementPoster: (NSView, String) -> Void = { element, announcement in
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [.announcement: announcement]
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 8

        // Border drawn as a shape layer (not `layer.border…`) so the degraded
        // variant can swap in a dashed stroke.
        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1
        layer?.addSublayer(borderLayer)

        contentClipView.wantsLayer = true
        contentClipView.layer?.masksToBounds = true
        contentClipView.layer?.cornerRadius = Metrics.cornerRadius
        contentClipView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentClipView)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Metrics.rowGap
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        // Yield to a clamped frame instead of fighting the required edge pins
        // with a required content size: pathological content compresses (its
        // wrapping rows truncate) and any residue is masked by the clip view.
        contentStack.setClippingResistancePriority(.defaultLow, for: .vertical)
        contentClipView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentClipView.topAnchor.constraint(equalTo: topAnchor),
            contentClipView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentClipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentClipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: contentClipView.topAnchor, constant: Metrics.insetTop),
            contentStack.bottomAnchor.constraint(equalTo: contentClipView.bottomAnchor, constant: -Metrics.insetTop),
            contentStack.leadingAnchor.constraint(equalTo: contentClipView.leadingAnchor, constant: Metrics.insetSide),
            contentStack.trailingAnchor.constraint(equalTo: contentClipView.trailingAnchor, constant: -Metrics.insetSide),
        ])

        // One stable VoiceOver landmark below the Recognized pane — a container
        // group, never flattened (TECH §F-8).
        setAccessibilityRole(.group)
        setAccessibilityLabel("Contextual translation")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Rendering

    /// Rebuilds the card for `state`. `span` is the user's (normalized) selection,
    /// echoed in the header row and bolded inside the example sentence.
    func render(_ state: State, span: String) {
        renderGeneration += 1
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        wrappingLabels = []
        skeletonBars = []
        saveButton = nil
        isSaving = false

        var axChildren: [Any] = []
        let header = headerRow(state: state, span: span, axChildren: &axChildren)
        contentStack.addArrangedSubview(header)
        pinToContentWidth(header)

        switch state {
        case .loading(let mode):
            addSkeletonRows(mode: mode)
        case .dictionary(let card):
            addDictionaryRows(card, span: span, axChildren: &axChildren)
        case .plain(let translation, let degraded):
            addPlainRows(translation: translation, degraded: degraded, axChildren: &axChildren)
        case .error:
            contentStack.addArrangedSubview(errorRow())
        }

        // Save and ✕ close the VoiceOver reading order (TECH §F-8).
        if let saveButton { axChildren.append(saveButton) }
        if let dismiss = dismissButtonInHeader() { axChildren.append(dismiss) }
        setAccessibilityChildren(axChildren)
        setAccessibilityLabel(Self.isLoading(state) ? "Translating selection…" : "Contextual translation")
        announceIfContent(state, span: span)

        borderLayer.lineDashPattern = Self.isDegraded(state) ? [4, 3] : nil
        applySaveKeyEquivalent()
        needsLayout = true
    }

    /// While a content state is up the panel routes ⌘S here; dismissal reverts
    /// it to the header Save button (TECH Fig. F7). Exactly one visible button
    /// holds "s"+⌘ at any moment — the panel drives both assignments.
    func setSaveKeyEquivalentActive(_ active: Bool) {
        isSaveKeyEquivalentActive = active
        applySaveKeyEquivalent()
    }

    /// The slot height this card needs for `state` at `width`, clamped to the
    /// 200 pt cap (DESIGN §02). The panel grows by this + spacing; the loading
    /// fill pre-reserves the mode-predicted height so the skeleton → content
    /// swap causes no jump on the typical path.
    static func fittingHeight(for state: State, span: String, width: CGFloat) -> CGFloat {
        let probe = SelectionCardView()
        probe.isMeasurementProbe = true // never announce from a view no one sees
        probe.render(state, span: span)
        probe.applyWrappingWidth(width - Metrics.insetSide * 2)
        let widthLimit = probe.widthAnchor.constraint(equalToConstant: width)
        widthLimit.isActive = true
        probe.layoutSubtreeIfNeeded()
        return min(probe.fittingSize.height, maxHeight)
    }

    override func layout() {
        super.layout()
        borderLayer.frame = bounds
        borderLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: Metrics.cornerRadius - 0.5,
            cornerHeight: Metrics.cornerRadius - 0.5,
            transform: nil
        )
        borderLayer.strokeColor = NSColor.separatorColor.cgColor
        applyWrappingWidth(bounds.width - Metrics.insetSide * 2)
    }

    // MARK: - Header row (span echo · mode chip · spacer · ☆ Save ⌘S · ✕)

    private func headerRow(state: State, span: String, axChildren: inout [Any]) -> NSView {
        let echo = NSTextField(labelWithString: span)
        echo.font = .systemFont(ofSize: 13, weight: .semibold)
        echo.textColor = .labelColor
        echo.lineBreakMode = .byTruncatingMiddle
        echo.maximumNumberOfLines = 1
        echo.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.spanEchoMaxWidth).isActive = true
        echo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        axChildren.append(echo)

        var views: [NSView] = [echo]
        if let chip = modeChip(for: state) {
            views.append(chip)
            axChildren.append(chip)
        }
        views.append(spacer())
        if Self.isContent(state), onSave != nil {
            views.append(makeSaveButton())
        }
        views.append(makeDismissButton())

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    /// Engine-identity chip: purple mirrors the existing AI badge; the degraded
    /// variant reads gray "Context-free · Google". Loading/error carry no chip —
    /// the serving engine isn't known (or didn't answer).
    private func modeChip(for state: State) -> NSView? {
        let text: String
        let tint: NSColor
        let fill: NSColor
        switch state {
        case .dictionary, .plain(_, false):
            text = "In context · AI"
            tint = .systemPurple
            fill = NSColor.systemPurple.withAlphaComponent(0.12)
        case .plain(_, true):
            text = "Context-free · Google"
            tint = .secondaryLabelColor
            fill = NSColor.gray.withAlphaComponent(0.07)
        case .loading, .error:
            return nil
        }

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = tint
        label.translatesAutoresizingMaskIntoConstraints = false

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 8
        pill.layer?.backgroundColor = fill.cgColor
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
        ])
        return pill
    }

    private func makeSaveButton() -> NSButton {
        let button = borderlessButton(title: "☆ Save ⌘S", action: #selector(saveTapped))
        button.toolTip = "Save selection to Notebook (⌘S)"
        button.setAccessibilityLabel("Save selection to Notebook")
        saveButton = button
        return button
    }

    private func makeDismissButton() -> NSButton {
        let button = borderlessButton(title: "✕", action: #selector(dismissTapped))
        button.toolTip = "Dismiss"
        button.setAccessibilityLabel("Dismiss contextual translation")
        return button
    }

    private func borderlessButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    /// The header ✕, found rather than stored: the header is rebuilt every
    /// render, and the AX reading order needs it last.
    private func dismissButtonInHeader() -> NSButton? {
        guard let row = contentStack.arrangedSubviews.first as? NSStackView else { return nil }
        return row.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.title == "✕" }
    }

    // MARK: - Dictionary fill (FR-3)

    private func addDictionaryRows(_ card: DictionaryCard, span: String, axChildren: inout [Any]) {
        let translation = wrappingLabel(
            card.translation, font: .systemFont(ofSize: 17, weight: .semibold),
            color: .labelColor, maxLines: Metrics.translationMaxLines
        )
        contentStack.addArrangedSubview(translation)
        pinToContentWidth(translation)
        axChildren.append(translation)

        // POS chip + sense share one row; the row is omitted when both are nil —
        // absent fields are never faked or rendered blank (FR-3).
        if card.partOfSpeech != nil || card.sense != nil {
            var views: [NSView] = []
            if let pos = card.partOfSpeech {
                let chip = posChip(pos)
                views.append(chip)
                axChildren.append(chip)
            }
            if let sense = card.sense {
                let label = wrappingLabel(sense, font: .systemFont(ofSize: 12),
                                          color: .secondaryLabelColor, maxLines: 2)
                views.append(label)
                axChildren.append(label)
            }
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            contentStack.addArrangedSubview(row)
            pinToContentWidth(row)
        }

        if let example = card.example {
            let hairline = NSBox()
            hairline.boxType = .separator
            contentStack.addArrangedSubview(hairline)
            pinToContentWidth(hairline)

            let exampleLabel = wrappingLabel("", font: .systemFont(ofSize: 12),
                                             color: .secondaryLabelColor, maxLines: 2)
            exampleLabel.attributedStringValue = Self.exampleText(example, bolding: span)
            contentStack.addArrangedSubview(exampleLabel)
            pinToContentWidth(exampleLabel)
            axChildren.append(exampleLabel)

            // An orphaned example translation (example == nil) is never shown.
            if let exampleTranslation = card.exampleTranslation {
                let label = wrappingLabel(exampleTranslation, font: .systemFont(ofSize: 12),
                                          color: .secondaryLabelColor, maxLines: 2)
                contentStack.addArrangedSubview(label)
                pinToContentWidth(label)
                axChildren.append(label)
            }
        }
    }

    private func posChip(_ pos: String) -> NSView {
        let label = NSTextField(labelWithString: pos)
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 4
        chip.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: chip.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -5),
        ])
        return chip
    }

    /// The example sentence with every occurrence of the selected span bolded
    /// in `labelColor` — the visual echo of what the user selected.
    private static func exampleText(_ example: String, bolding span: String) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: example,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        guard !span.isEmpty else { return text }
        var search = example.startIndex..<example.endIndex
        while let found = example.range(of: span, options: .caseInsensitive, range: search) {
            text.addAttributes(
                [
                    .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                ],
                range: NSRange(found, in: example)
            )
            search = found.upperBound..<example.endIndex
        }
        return text
    }

    // MARK: - Plain / degraded fill (FR-4 / FR-5)

    private func addPlainRows(translation: String, degraded: Bool, axChildren: inout [Any]) {
        // Long-span block: 15 regular, wraps freely (the 200 pt cap clamps
        // pathological content; long content belongs here, not the dictionary).
        let label = wrappingLabel(translation, font: .systemFont(ofSize: 15),
                                  color: .labelColor, maxLines: 0)
        contentStack.addArrangedSubview(label)
        pinToContentWidth(label)
        axChildren.append(label)

        if degraded {
            let note = wrappingLabel(
                "Translated without sentence context — add an AI key in Preferences for in-context results.",
                font: .systemFont(ofSize: 11), color: .tertiaryLabelColor, maxLines: 2
            )
            contentStack.addArrangedSubview(note)
            pinToContentWidth(note)
            axChildren.append(note)
        }
    }

    // MARK: - Error fill (quiet, inline — never a dialog)

    private func errorRow() -> NSView {
        let label = NSTextField(labelWithString: "Couldn’t translate the selection")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor

        let retry = NSButton(title: "Try again", target: self, action: #selector(retryTapped))
        retry.isBordered = false
        retry.font = .systemFont(ofSize: 12, weight: .medium)
        retry.contentTintColor = .controlAccentColor

        let row = NSStackView(views: [label, retry])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    // MARK: - Loading skeleton

    /// Placeholder bars sized by the predicted mode so the skeleton reserves
    /// the height the content will need: word/phrase ≈ the full card (headline
    /// + sense + example pair), long span ≈ the short plain block.
    private func addSkeletonRows(mode: SelectionMode) {
        let rows: [(fraction: CGFloat, height: CGFloat)] = switch mode {
        case .wordPhrase: [(0.55, 20), (0.8, 12), (0.9, 12), (0.7, 12)]
        case .longSpan: [(0.9, 16), (0.6, 16)]
        }
        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for row in rows {
            let bar = SkeletonBar(animated: animated)
            contentStack.addArrangedSubview(bar)
            NSLayoutConstraint.activate([
                bar.heightAnchor.constraint(equalToConstant: row.height),
                bar.widthAnchor.constraint(equalTo: contentStack.widthAnchor, multiplier: row.fraction),
            ])
            skeletonBars.append(bar)
        }
    }

    /// One shimmer bar: quiet fill + a compositor-friendly gradient sweep
    /// (CAGradientLayer + CABasicAnimation); a static bar under Reduce Motion.
    /// Never a VoiceOver element — the group's "Translating selection…" label
    /// speaks for the whole busy card (TECH §F-8).
    private final class SkeletonBar: NSView {
        private let gradient = CAGradientLayer()

        init(animated: Bool) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 4
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            translatesAutoresizingMaskIntoConstraints = false
            setAccessibilityElement(false)

            guard animated else { return }
            gradient.colors = [
                NSColor.clear.cgColor,
                NSColor.labelColor.withAlphaComponent(0.08).cgColor,
                NSColor.clear.cgColor,
            ]
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            layer?.addSublayer(gradient)

            let sweep = CABasicAnimation(keyPath: "transform.translation.x")
            sweep.fromValue = -1.0
            sweep.toValue = 1.0
            sweep.duration = 1.2
            sweep.repeatCount = .infinity
            gradient.add(sweep, forKey: "shimmer")
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            gradient.frame = bounds
            // Re-scope the sweep to the bar's real width once it is laid out.
            if gradient.animation(forKey: "shimmer") != nil {
                gradient.removeAnimation(forKey: "shimmer")
                let sweep = CABasicAnimation(keyPath: "transform.translation.x")
                sweep.fromValue = -bounds.width
                sweep.toValue = bounds.width
                sweep.duration = 1.2
                sweep.repeatCount = .infinity
                gradient.add(sweep, forKey: "shimmer")
            }
        }
    }

    // MARK: - Actions

    @objc private func dismissTapped() { onDismiss?() }
    @objc private func retryTapped() { onRetry?() }

    /// Async-confirm save, mirroring the header's `SaveButtonController`:
    /// disable → await → "★ Saved" (or re-enable to retry on failure) — a
    /// second click can never double-save.
    @objc private func saveTapped() {
        guard let onSave, !isSaving else { return }
        isSaving = true
        let generation = renderGeneration
        let button = saveButton
        button?.isEnabled = false
        saveTaskForTests = Task { @MainActor in
            let saved = await onSave()
            // Staleness guard (the F-3 token pattern): a re-render means this
            // result belongs to a superseded selection — leave the new card's
            // controls (and its own in-flight `isSaving`) untouched.
            guard generation == renderGeneration else { return }
            isSaving = false
            if saved {
                button?.title = "★ Saved"
                button?.contentTintColor = .systemPurple
            } else {
                button?.isEnabled = true
            }
        }
    }

    // MARK: - Helpers

    private static func isLoading(_ state: State) -> Bool {
        if case .loading = state { return true }
        return false
    }

    private static func isContent(_ state: State) -> Bool {
        switch state {
        case .dictionary, .plain: return true
        case .loading, .error: return false
        }
    }

    private static func isDegraded(_ state: State) -> Bool {
        if case .plain(_, true) = state { return true }
        return false
    }

    /// VoiceOver hears the result the moment it lands: "span — translation,
    /// POS" for content states only (loading/error announce nothing, and the
    /// off-screen `fittingHeight` probe never speaks — F-8: one announcement,
    /// tied to the mounted render).
    private func announceIfContent(_ state: State, span: String) {
        guard !isMeasurementProbe else { return }
        let announcement: String
        switch state {
        case .dictionary(let card):
            let pos = card.partOfSpeech.map { ", \($0)" } ?? ""
            announcement = "\(span) — \(card.translation)\(pos)"
        case .plain(let translation, _):
            announcement = "\(span) — \(translation)"
        case .loading, .error:
            return
        }
        Self.announcementPoster(self, announcement)
    }

    private func applySaveKeyEquivalent() {
        guard let saveButton else { return }
        saveButton.keyEquivalent = isSaveKeyEquivalentActive ? "s" : ""
        saveButton.keyEquivalentModifierMask = isSaveKeyEquivalentActive ? .command : []
    }

    private func wrappingLabel(
        _ text: String, font: NSFont, color: NSColor, maxLines: Int
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = maxLines
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = false
        wrappingLabels.append(label)
        return label
    }

    /// Wrapping rows must be told their width before they can report a true
    /// multi-line height — applied on every layout pass and by `fittingHeight`.
    private func applyWrappingWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        for label in wrappingLabels { label.preferredMaxLayoutWidth = width }
    }

    /// Pins a row to the content stack's full width so wrapped text and the
    /// hairline span the card (the stack itself is inset from the card edges).
    private func pinToContentWidth(_ view: NSView) {
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    // MARK: - Test seams

    // Internal (not private) so `@testable` tests can assert the degraded
    // styling flag and the busy skeleton headlessly — same pattern as the
    // panel's read-aloud seams. Not part of the production surface.

    var hasDashedBorderForTests: Bool { borderLayer.lineDashPattern != nil }
    var skeletonBarCountForTests: Int { skeletonBars.count }
}
