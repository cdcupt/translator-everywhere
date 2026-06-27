import AppKit
import Testing
@testable import Translator_Everywhere

/// The From / ⇄ / To bar's pure rendering (slice 7; beta A2/A6/A8/A11/A13). Drives
/// `LanguageBarView.render(pair:detected:)` headlessly and asserts the visible
/// labels, the secondary "Detected: …" line, and the swap button's enabled state —
/// the wiring the on-device beta panel marked BLOCKED. The transient picker popover
/// is validated on-device; this covers the bar surface the panel always shows.
@MainActor
@Suite("LanguageBarView — render From/To, Detected line, swap")
struct LanguageBarViewTests {

    private let zh = LanguageCatalog.language(forCode: "zh-CN")!
    private let en = LanguageCatalog.language(forCode: "en")!
    private let ja = LanguageCatalog.language(forCode: "ja")!

    // A2 — the From control reads "Auto" when the source is auto-detected.
    @Test("From label reads Auto when the pair has no explicit source")
    func autoFromLabel() {
        let bar = LanguageBarView()
        bar.render(pair: LanguagePair(from: nil, to: zh), detected: .unavailable)
        #expect(bar.fromButton.title == "From: Auto  ▾")
        #expect(bar.toButton.title == "To: \(zh.endonym)  ▾")
    }

    // A8 — the "Detected: …" line shows ONLY for Auto + an identified source.
    @Test("Detected line shows only when From is Auto and detection identified a language")
    func detectedLineVisibility() {
        let bar = LanguageBarView()

        // Auto + identified → visible, prefixed "Detected:" and naming the language.
        bar.render(pair: LanguagePair(from: nil, to: zh),
                   detected: .identified(ja, confidence: 0.9))
        #expect(bar.detectedLabel.isHidden == false)
        #expect(bar.detectedLabel.stringValue.hasPrefix("Detected:"))
        #expect(bar.detectedLabel.stringValue.contains(ja.englishName))

        // Explicit From → hidden even when detection identified something.
        bar.render(pair: LanguagePair(from: en, to: zh),
                   detected: .identified(ja, confidence: 0.9))
        #expect(bar.detectedLabel.isHidden)

        // Auto but detection unavailable / uncertain → hidden (no flip risk shown).
        bar.render(pair: LanguagePair(from: nil, to: zh), detected: .unavailable)
        #expect(bar.detectedLabel.isHidden)
        bar.render(pair: LanguagePair(from: nil, to: zh), detected: .uncertain)
        #expect(bar.detectedLabel.isHidden)
    }

    // A6 (view surface) — swap is enabled only with a concrete source to promote.
    @Test("Swap is disabled only when there is no concrete source to promote")
    func swapEnabledState() {
        let bar = LanguageBarView()
        bar.render(pair: LanguagePair(from: nil, to: zh), detected: .unavailable)
        #expect(bar.swapButton.isEnabled == false)            // Auto, nothing detected
        bar.render(pair: LanguagePair(from: nil, to: zh),
                   detected: .identified(ja, confidence: nil))
        #expect(bar.swapButton.isEnabled)                     // Auto + detected source
        bar.render(pair: LanguagePair(from: en, to: zh), detected: .unavailable)
        #expect(bar.swapButton.isEnabled)                     // explicit From
    }

    // A11/A13 — the bar surfaces the effective target the same-language guard chose.
    @Test("To label reflects the guard's effective target (flip and no-flip)")
    func effectiveTargetSurfacing() {
        let bar = LanguageBarView()

        // Home zh, capture Chinese under Auto → guard flips to the secondary (en).
        let flipped = PairResolver.effectiveTo(
            detected: .identified(zh, confidence: nil),
            pair: LanguagePair(from: nil, to: zh), secondary: en)
        #expect(flipped.code == en.code)
        bar.render(pair: LanguagePair(from: nil, to: flipped),
                   detected: .identified(zh, confidence: nil))
        #expect(bar.toButton.title == "To: \(en.endonym)  ▾")

        // Detected ja ≠ chosen to (zh) → no flip, the To label stays zh.
        let kept = PairResolver.effectiveTo(
            detected: .identified(ja, confidence: nil),
            pair: LanguagePair(from: nil, to: zh), secondary: en)
        #expect(kept.code == zh.code)
        bar.render(pair: LanguagePair(from: nil, to: kept),
                   detected: .identified(ja, confidence: nil))
        #expect(bar.toButton.title == "To: \(zh.endonym)  ▾")
    }
}
