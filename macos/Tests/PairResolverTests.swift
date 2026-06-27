import Foundation
import Testing
@testable import Translator_Everywhere

/// The pure same-language guard (Slice 2). These cases are the deterministic S5
/// regression surface: with home = 中文 and secondary = English, the guard must
/// reproduce the old two-language EN⇄ZH flip and nothing else.
@Suite("PairResolver — same-language guard")
struct PairResolverTests {

    private let english = LanguageCatalog.language(forCode: "en")!
    private let chinese = LanguageCatalog.language(forCode: "zh-CN")!
    private let japanese = LanguageCatalog.language(forCode: "ja")!

    @Test("EN→中文: Auto-detecting English with home=中文 does not flip (one call)")
    func englishToChineseDoesNotFlip() {
        let pair = LanguagePair(from: nil, to: chinese)
        let detected = DetectedSource.identified(english, confidence: 0.98)
        let target = PairResolver.effectiveTo(detected: detected, pair: pair, secondary: english)
        #expect(target.code == chinese.code) // English → 中文, no flip
    }

    @Test("中文→EN: detected zh == to(中文) flips to the secondary (English)")
    func chineseToEnglishFlips() {
        let pair = LanguagePair(from: nil, to: chinese)
        let detected = DetectedSource.identified(chinese, confidence: 0.95)
        let target = PairResolver.effectiveTo(detected: detected, pair: pair, secondary: english)
        #expect(target.code == english.code) // guard fires — the old EN⇄ZH flip
    }

    @Test("JP→中文: detected ja != to(中文) does not flip")
    func japaneseToChineseDoesNotFlip() {
        let pair = LanguagePair(from: nil, to: chinese)
        let detected = DetectedSource.identified(japanese, confidence: 0.9)
        let target = PairResolver.effectiveTo(detected: detected, pair: pair, secondary: english)
        #expect(target.code == chinese.code)
    }

    @Test("Explicit From bypasses the guard even on a collision")
    func explicitFromBypassesGuard() {
        let pair = LanguagePair(from: english, to: chinese) // explicit From
        let detected = DetectedSource.identified(chinese, confidence: 0.95)
        let target = PairResolver.effectiveTo(detected: detected, pair: pair, secondary: english)
        #expect(target.code == chinese.code) // no flip — From was chosen by the user
    }

    @Test("Uncertain detection suppresses the guard")
    func uncertainSuppressesGuard() {
        let pair = LanguagePair(from: nil, to: chinese)
        let target = PairResolver.effectiveTo(detected: .uncertain, pair: pair, secondary: english)
        #expect(target.code == chinese.code)
    }

    @Test("Unavailable detection suppresses the guard")
    func unavailableSuppressesGuard() {
        let pair = LanguagePair(from: nil, to: chinese)
        let target = PairResolver.effectiveTo(detected: .unavailable, pair: pair, secondary: english)
        #expect(target.code == chinese.code)
    }

    @Test("No distinct secondary falls through to `to`")
    func noDistinctSecondaryFallsThrough() {
        let pair = LanguagePair(from: nil, to: chinese)
        let detected = DetectedSource.identified(chinese, confidence: 0.95)

        // secondary == to → not distinct
        let sameSecondary = PairResolver.effectiveTo(detected: detected, pair: pair, secondary: chinese)
        #expect(sameSecondary.code == chinese.code)

        // secondary nil → nothing to flip to
        let noSecondary = PairResolver.effectiveTo(detected: detected, pair: pair, secondary: nil)
        #expect(noSecondary.code == chinese.code)
    }
}
