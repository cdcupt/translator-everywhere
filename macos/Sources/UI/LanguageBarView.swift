import AppKit

/// Tap callbacks from the language bar. The controller owns the picker + the
/// `LanguagePair`; the view is pure presentation and just forwards intent.
@MainActor
protocol LanguageBarViewDelegate: AnyObject {
    /// The From control was tapped — open the From picker anchored to `source`.
    func languageBarDidTapFrom(_ bar: LanguageBarView, source: NSView)
    /// The To control was tapped — open the To picker anchored to `source`.
    func languageBarDidTapTo(_ bar: LanguageBarView, source: NSView)
    /// The ⇄ swap control was tapped.
    func languageBarDidTapSwap(_ bar: LanguageBarView)
}

/// The From / ⇄ / To bar plus the secondary "Detected:" line (DESIGN §9, mockup).
///
/// Pure presentation: `render(pair:detected:)` draws a `LanguagePair` +
/// `DetectedSource` and forwards taps to its delegate. Labels truncate to the
/// endonym and never wrap, so the bar always fits the 440-pt panel width. From
/// shows "Auto" with a "Detected: …" sub-line when the source is auto-detected,
/// or the chosen language otherwise; the ⇄ button is disabled when there is no
/// concrete source to promote.
@MainActor
final class LanguageBarView: NSView {

    weak var delegate: LanguageBarViewDelegate?

    let fromButton = NSButton()
    let swapButton = NSButton()
    let toButton = NSButton()
    private let detectedLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Rendering

    /// Draws the current pair + detection: From label/Detected sub-line, To label,
    /// the swap button's enabled state, and VoiceOver labels.
    func render(pair: LanguagePair, detected: DetectedSource) {
        let fromName = pair.from?.endonym ?? "Auto"
        fromButton.title = "From: \(fromName)  ▾"
        toButton.title = "To: \(pair.to.endonym)  ▾"

        // Swap needs a concrete source to promote into From: the explicit From, or
        // (when Auto) the detected language. Disabled when neither exists.
        swapButton.isEnabled = (pair.from ?? Self.detectedLanguage(detected)) != nil

        if pair.from == nil, let language = Self.detectedLanguage(detected) {
            detectedLabel.stringValue = "Detected: \(Self.detectedName(language))"
            detectedLabel.isHidden = false
        } else {
            detectedLabel.stringValue = ""
            detectedLabel.isHidden = true
        }

        fromButton.setAccessibilityLabel(
            "Translate from \(pair.from?.englishName ?? "auto-detected source"). Activate to change the source language."
        )
        toButton.setAccessibilityLabel(
            "Translate to \(pair.to.englishName). Activate to change the target language."
        )
        swapButton.setAccessibilityLabel("Swap source and target languages")
    }

    // MARK: - Construction

    private func build() {
        let row = NSStackView(views: [
            makePill(fromButton, action: #selector(fromTapped)),
            makeSwap(),
            makePill(toButton, action: #selector(toTapped)),
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)

        // The From control hugs its content; the To control fills the remaining
        // width and is the first to truncate, so the bar never overflows or wraps.
        fromButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        fromButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        toButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 9
        box.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: box.topAnchor),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])

        detectedLabel.font = .systemFont(ofSize: 11)
        detectedLabel.textColor = .secondaryLabelColor
        detectedLabel.lineBreakMode = .byTruncatingTail
        detectedLabel.maximumNumberOfLines = 1
        detectedLabel.isHidden = true

        let stack = NSStackView(views: [box, detectedLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            // The bar box spans the full bar width so To can fill / truncate.
            box.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func makePill(_ button: NSButton, action: Selector) -> NSButton {
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.target = self
        button.action = action
        button.focusRingType = .default
        button.cell?.usesSingleLineMode = true
        button.cell?.lineBreakMode = .byTruncatingTail
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func makeSwap() -> NSButton {
        swapButton.bezelStyle = .rounded
        swapButton.setButtonType(.momentaryPushIn)
        swapButton.title = "⇄"
        swapButton.font = .systemFont(ofSize: 14, weight: .medium)
        swapButton.target = self
        swapButton.action = #selector(swapTapped)
        swapButton.toolTip = "Swap source and target languages"
        swapButton.focusRingType = .default
        swapButton.translatesAutoresizingMaskIntoConstraints = false
        swapButton.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            swapButton.widthAnchor.constraint(equalToConstant: 36),
        ])
        return swapButton
    }

    // MARK: - Actions

    @objc private func fromTapped() { delegate?.languageBarDidTapFrom(self, source: fromButton) }
    @objc private func toTapped() { delegate?.languageBarDidTapTo(self, source: toButton) }
    @objc private func swapTapped() { delegate?.languageBarDidTapSwap(self) }

    // MARK: - Helpers

    /// The detected `Language` when detection identified one, else `nil`.
    private static func detectedLanguage(_ detected: DetectedSource) -> Language? {
        if case let .identified(language, _) = detected { return language }
        return nil
    }

    /// "endonym · EnglishName" when the two differ, else just the name — so the
    /// "Detected:" line reads naturally for both Latin and non-Latin scripts.
    private static func detectedName(_ language: Language) -> String {
        language.endonym == language.englishName
            ? language.englishName
            : "\(language.endonym) · \(language.englishName)"
    }
}
