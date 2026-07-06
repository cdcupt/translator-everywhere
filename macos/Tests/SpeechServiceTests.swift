import AppKit
import Testing
@testable import Translator_Everywhere

/// Read-aloud (TTS): the pure BCP-47 → installed-voice matcher, and the
/// `ResultPanel` speaker wiring driven headlessly through a spy synthesizer.
@MainActor
@Suite("Read aloud — voice resolver + speaker wiring")
struct SpeechServiceTests {

    // A representative installed-voice set (macOS ships regioned tags).
    private let available = [
        "en-US", "en-GB", "zh-CN", "zh-TW", "pt-BR", "pt-PT", "es-ES", "ar-001", "ja-JP",
    ]

    // MARK: - SpeechVoiceResolver (pure)

    @Test("Exact regioned code matches its own tag")
    func exactMatch() {
        #expect(SpeechVoiceResolver.match(code: "zh-CN", available: available) == "zh-CN")
        #expect(SpeechVoiceResolver.match(code: "zh-TW", available: available) == "zh-TW")
    }

    @Test("Bare primary subtag matches a regioned voice of that language")
    func primarySubtagMatch() {
        #expect(SpeechVoiceResolver.match(code: "en", available: available) == "en-US")
        #expect(SpeechVoiceResolver.match(code: "pt", available: available) == "pt-BR")
        #expect(SpeechVoiceResolver.match(code: "ar", available: available) == "ar-001")
    }

    @Test("Matching is case-insensitive")
    func caseInsensitive() {
        #expect(SpeechVoiceResolver.match(code: "ZH-cn", available: available) == "zh-CN")
        #expect(SpeechVoiceResolver.match(code: "EN", available: available) == "en-US")
    }

    @Test("A language with no installed voice does not match")
    func noMatch() {
        // Aymara, Bhojpuri, Ewe, Filipino — real catalog codes with no macOS voice.
        for code in ["ay", "bho", "ee", "fil", "xx"] {
            #expect(SpeechVoiceResolver.match(code: code, available: available) == nil)
        }
    }

    @Test("A nil or empty code never matches")
    func nilOrEmpty() {
        #expect(SpeechVoiceResolver.match(code: nil, available: available) == nil)
        #expect(SpeechVoiceResolver.match(code: "", available: available) == nil)
    }

    @Test("Norwegian 'no' matches the installed Bokmål (nb) voice")
    func norwegianMacrolanguageAlias() {
        #expect(SpeechVoiceResolver.match(code: "no", available: ["nb-NO", "en-US"]) == "nb-NO")
        // …and the reverse: a "nb" request still matches "nb-NO".
        #expect(SpeechVoiceResolver.match(code: "nb", available: ["nb-NO", "en-US"]) == "nb-NO")
    }

    // MARK: - ResultPanel speaker wiring (spy)

    private func makePanel(speakable: Set<String>) -> (ResultPanel, SpeechSpy) {
        let spy = SpeechSpy(speakable: speakable)
        return (ResultPanel(speech: spy), spy)
    }

    private var english: Language { LanguageCatalog.language(forCode: "en")! }
    private var spanish: Language { LanguageCatalog.language(forCode: "es")! }

    @Test("Each pane is read in its own language, live text")
    func readsPerPaneLanguage() {
        let (panel, spy) = makePanel(speakable: ["es", "en"])
        let body = panel.buildResultBodyForTests(
            translation: "Hola mundo", source: "Hello world",
            pair: LanguagePair(from: english, to: spanish),
            detected: .identified(english, confidence: nil)
        )
        _ = body // retain the view hierarchy the panel weakly references

        panel.tapTranslationSpeakerForTests()
        #expect(spy.spoken.count == 1)
        #expect(spy.spoken.last?.text == "Hola mundo")
        #expect(spy.spoken.last?.code == "es")
        #expect(panel.isReadingTranslationForTests)

        panel.tapSourceSpeakerForTests()
        #expect(spy.spoken.count == 2)
        #expect(spy.spoken.last?.text == "Hello world")
        #expect(spy.spoken.last?.code == "en")
        // Switching panes hands the active state to the source pane.
        #expect(panel.isReadingSourceForTests)
        #expect(!panel.isReadingTranslationForTests)
    }

    @Test("Re-tapping the reading pane stops it")
    func reTapStops() {
        let (panel, spy) = makePanel(speakable: ["es"])
        let body = panel.buildResultBodyForTests(
            translation: "Hola", source: "Hello",
            pair: LanguagePair(from: english, to: spanish), detected: .unavailable
        )
        _ = body

        panel.tapTranslationSpeakerForTests()
        #expect(panel.isReadingTranslationForTests)
        panel.tapTranslationSpeakerForTests()
        #expect(spy.stopCount >= 1)
        #expect(!panel.isReadingTranslationForTests)
    }

    @Test("A finished utterance resets the reading state via the wired callback")
    func finishResets() {
        let (panel, spy) = makePanel(speakable: ["es"])
        let body = panel.buildResultBodyForTests(
            translation: "Hola", source: "Hello",
            pair: LanguagePair(from: english, to: spanish), detected: .unavailable
        )
        _ = body

        panel.tapTranslationSpeakerForTests()
        #expect(panel.isReadingTranslationForTests)
        // Fire the callback the panel wired in init (not the internal seam), so the
        // real end-to-end reset path is exercised.
        spy.onFinish?()
        #expect(!panel.isReadingTranslationForTests)
    }

    @Test("Retranslating stops read-aloud and re-points the speakers")
    func retranslateHaltsAndRepoints() {
        let french = LanguageCatalog.language(forCode: "fr")!
        // Spanish is speakable, French is not.
        let (panel, spy) = makePanel(speakable: ["es"])
        let body = panel.buildResultBodyForTests(
            translation: "Hola", source: "Hello",
            pair: LanguagePair(from: english, to: spanish),
            detected: .identified(english, confidence: nil)
        )
        _ = body

        panel.tapTranslationSpeakerForTests()
        #expect(panel.isReadingTranslationForTests)

        // Retranslate to a French target with a Spanish source, no detection.
        panel.updateResult(
            translation: "Bonjour", source: "Hola",
            badge: "AI", copied: false,
            pair: LanguagePair(from: spanish, to: french),
            detected: .unavailable,
            viaGoogleFallback: false,
            onSave: nil, onRetranslate: nil
        )

        // Stale audio is stopped and the reading state cleared.
        #expect(spy.stopCount >= 1)
        #expect(!panel.isReadingTranslationForTests)
        // Speakers now track the new languages: French translation has no voice
        // (hidden), the Spanish source does (shown).
        #expect(panel.translationSpeakerIsHiddenForTests == true)
        #expect(panel.sourceSpeakerIsHiddenForTests == false)
    }

    @Test("The speaker button hides when the pane's language has no voice")
    func hidesWhenNoVoice() {
        // Target Spanish is speakable; source English is not → its speaker hides.
        let (panel, _) = makePanel(speakable: ["es"])
        let body = panel.buildResultBodyForTests(
            translation: "Hola", source: "Hello",
            pair: LanguagePair(from: english, to: spanish),
            detected: .identified(english, confidence: nil)
        )
        _ = body

        #expect(panel.translationSpeakerIsHiddenForTests == false)
        #expect(panel.sourceSpeakerIsHiddenForTests == true)
    }

    @Test("Empty pane text speaks nothing")
    func emptyTextIsNoOp() {
        let (panel, spy) = makePanel(speakable: ["es"])
        let body = panel.buildResultBodyForTests(
            translation: "   ", source: "Hello",
            pair: LanguagePair(from: english, to: spanish), detected: .unavailable
        )
        _ = body

        panel.tapTranslationSpeakerForTests()
        #expect(spy.spoken.isEmpty)
        #expect(!panel.isReadingTranslationForTests)
    }
}

/// A spy `SpeechSynthesizing` that records what it was asked to speak and which
/// languages it claims to voice, without touching `AVFoundation`.
@MainActor
private final class SpeechSpy: SpeechSynthesizing {
    var onFinish: (@MainActor () -> Void)?
    private(set) var spoken: [(text: String, code: String?)] = []
    private(set) var stopCount = 0
    private let speakable: Set<String>

    init(speakable: Set<String>) {
        self.speakable = speakable
    }

    func speak(_ text: String, languageCode: String?) {
        spoken.append((text, languageCode))
    }

    func stop() { stopCount += 1 }

    func canSpeak(languageCode: String?) -> Bool {
        guard let languageCode else { return false }
        return speakable.contains(languageCode)
    }
}
