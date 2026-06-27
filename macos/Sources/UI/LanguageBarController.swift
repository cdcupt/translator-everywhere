import AppKit

/// Owns the From/To language bar and its picker popover (TECH §8.1, slice 7).
///
/// `ResultPanel` holds this strongly (mirroring `saveButtonController`) for the
/// lifetime of the shown result; the bar's `NSButton` targets are non-owning, so
/// without that strong reference this controller — and its popover state — would
/// dealloc out from under the live bar. It tracks the current `LanguagePair` +
/// `DetectedSource`, translates a pick (From/To/⇄) into a new pair, applies it to
/// the bar optimistically, and reports it via `onPick`. Picking the pair already
/// shown is a no-op (no needless re-translation).
@MainActor
final class LanguageBarController: NSObject, LanguageBarViewDelegate {

    /// The bar view to embed in the result layout.
    var view: NSView { bar }

    /// Called with the user's newly chosen pair (the From/To change or a ⇄ swap).
    /// `ResultPanel` wires this to show in-place "translating…" feedback and fire
    /// the coordinator's `onRetranslate`.
    var onPick: ((LanguagePair) -> Void)?

    private let bar = LanguageBarView()
    private let picker = LanguagePickerController()
    private let recentProvider: () -> [Language]

    private var pair: LanguagePair
    private var detected: DetectedSource

    init(
        pair: LanguagePair,
        detected: DetectedSource,
        recentProvider: @escaping () -> [Language]
    ) {
        self.pair = pair
        self.detected = detected
        self.recentProvider = recentProvider
        super.init()
        bar.delegate = self
        bar.render(pair: pair, detected: detected)
    }

    /// Refreshes the bar for a new pair/detection (called when a result re-renders
    /// in place after a retranslate).
    func update(pair: LanguagePair, detected: DetectedSource) {
        self.pair = pair
        self.detected = detected
        bar.render(pair: pair, detected: detected)
    }

    // MARK: - LanguageBarViewDelegate

    func languageBarDidTapFrom(_ bar: LanguageBarView, source: NSView) {
        picker.present(from: source, mode: .from, recent: recentProvider()) { [weak self] choice in
            self?.applyFrom(choice)
        }
    }

    func languageBarDidTapTo(_ bar: LanguageBarView, source: NSView) {
        picker.present(from: source, mode: .to, recent: recentProvider()) { [weak self] choice in
            self?.applyTo(choice)
        }
    }

    func languageBarDidTapSwap(_ bar: LanguageBarView) {
        // Promote the concrete source — the explicit From, or the detected source
        // when From is Auto — into To, and the old To into From (mockup parity).
        guard let source = Self.detectedLanguage(from: pair, detected: detected) else { return }
        commit(LanguagePair(from: pair.to, to: source))
    }

    // MARK: - Pick handling

    /// Applies a From-picker choice. The picker callback (and the controller/view
    /// tests) call this directly; it commits the resulting pair via `commit`.
    func applyFrom(_ choice: LanguageChoice) {
        switch choice {
        case .auto:
            commit(LanguagePair(from: nil, to: pair.to))
        case let .language(language):
            commit(LanguagePair(from: language, to: pair.to))
        }
    }

    /// Applies a To-picker choice (see `applyFrom`).
    func applyTo(_ choice: LanguageChoice) {
        guard case let .language(language) = choice else { return }
        commit(LanguagePair(from: pair.from, to: language))
    }

    /// Applies `newPair` to the bar immediately and reports it — unless it equals
    /// the current pair, in which case nothing changed and we skip the retranslate.
    private func commit(_ newPair: LanguagePair) {
        guard newPair != pair else { return }
        update(pair: newPair, detected: detected)
        onPick?(newPair)
    }

    /// The concrete source available to swap into From: the explicit From, else
    /// the detected language when From is Auto, else `nil`.
    private static func detectedLanguage(from pair: LanguagePair, detected: DetectedSource) -> Language? {
        if let from = pair.from { return from }
        if case let .identified(language, _) = detected { return language }
        return nil
    }
}
