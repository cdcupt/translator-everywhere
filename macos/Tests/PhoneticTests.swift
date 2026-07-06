import AppKit
import Testing
@testable import Translator_Everywhere

/// IPA phonetics (音标): the pure transcriber + English gate, the async service
/// over an injected dictionary, and the `ResultPanel` render seam.
@MainActor
@Suite("Phonetics — transcriber + service + panel line")
struct PhoneticTests {

    private let dict = [
        "hello": "həˈloʊ", "world": "ˈwɝld", "it's": "ɪts", "read": "ˈɹɛd",
    ]

    // MARK: - PhoneticTranscriber (pure)

    @Test("Transcribes known words, case-insensitively, dropping edge punctuation")
    func knownWords() {
        #expect(PhoneticTranscriber.transcribe("Hello, WORLD!", dictionary: dict) == "həˈloʊ ˈwɝld")
        #expect(PhoneticTranscriber.transcribe("(hello)", dictionary: dict) == "həˈloʊ")
    }

    @Test("Unknown words are kept in place so the line still reads left-to-right")
    func unknownWordsKept() {
        #expect(PhoneticTranscriber.transcribe("hello foobar world", dictionary: dict)
            == "həˈloʊ foobar ˈwɝld")
    }

    @Test("Returns nil when no word is known")
    func noneKnown() {
        #expect(PhoneticTranscriber.transcribe("foobar bazqux", dictionary: dict) == nil)
        #expect(PhoneticTranscriber.transcribe("", dictionary: dict) == nil)
        #expect(PhoneticTranscriber.transcribe("   \n\t", dictionary: dict) == nil)
        #expect(PhoneticTranscriber.transcribe("!!! ...", dictionary: dict) == nil)
    }

    @Test("Curly and straight apostrophes both match the dictionary key")
    func apostropheFolding() {
        #expect(PhoneticTranscriber.transcribe("It's", dictionary: dict) == "ɪts")
        #expect(PhoneticTranscriber.transcribe("it\u{2019}s", dictionary: dict) == "ɪts")
    }

    @Test("Words glued by slash or em/en dash are split and both transcribed")
    func internalSeparators() {
        #expect(PhoneticTranscriber.transcribe("hello/world", dictionary: dict) == "həˈloʊ ˈwɝld")
        #expect(PhoneticTranscriber.transcribe("hello\u{2014}world", dictionary: dict) == "həˈloʊ ˈwɝld")
        #expect(PhoneticTranscriber.transcribe("hello\u{2013}world", dictionary: dict) == "həˈloʊ ˈwɝld")
    }

    @Test("Splits on Unicode whitespace (NBSP, ideographic space)")
    func unicodeWhitespace() {
        #expect(PhoneticTranscriber.transcribe("hello\u{00A0}world", dictionary: dict) == "həˈloʊ ˈwɝld")
        #expect(PhoneticTranscriber.transcribe("hello\u{3000}world", dictionary: dict) == "həˈloʊ ˈwɝld")
    }

    @Test("Recovers a word wrapped in typographic quotes; drops lone punctuation")
    func quotedWordAndLonePunctuation() {
        #expect(PhoneticTranscriber.transcribe("\u{2018}hello\u{2019}", dictionary: dict) == "həˈloʊ")
        #expect(PhoneticTranscriber.transcribe("hello - world", dictionary: dict) == "həˈloʊ ˈwɝld")
    }

    // MARK: - PhoneticLanguage (pure)

    @Test("English gate accepts en / en-* only")
    func englishGate() {
        #expect(PhoneticLanguage.isEnglish("en"))
        #expect(PhoneticLanguage.isEnglish("en-US"))
        #expect(PhoneticLanguage.isEnglish("EN"))
        #expect(!PhoneticLanguage.isEnglish("es"))
        #expect(!PhoneticLanguage.isEnglish("eng"))
        #expect(!PhoneticLanguage.isEnglish(nil))
    }

    // MARK: - PhoneticService (async, injected dictionary)

    @Test("Service transcribes English and gates out other languages")
    func serviceEnglishOnly() async {
        let service = PhoneticService(loader: { ["hello": "həˈloʊ", "world": "ˈwɝld"] })
        let english = await service.ipa(for: "Hello, world!", languageCode: "en")
        #expect(english == "həˈloʊ ˈwɝld")

        let nonEnglish = await service.ipa(for: "你好 世界", languageCode: "zh-CN")
        #expect(nonEnglish == nil)

        // Loads the dictionary once and reuses it for a second call.
        let again = await service.ipa(for: "world", languageCode: "en")
        #expect(again == "ˈwɝld")
    }

    // MARK: - ResultPanel phonetic line

    private var english: Language { LanguageCatalog.language(forCode: "en")! }
    private var spanish: Language { LanguageCatalog.language(forCode: "es")! }

    @Test("A non-English pane hides its phonetic line synchronously")
    func nonEnglishPaneHidden() {
        let panel = ResultPanel(phonetic: StubPhonetic(result: nil))
        let body = panel.buildResultBodyForTests(
            translation: "Hola mundo", source: "Hello world",
            pair: LanguagePair(from: english, to: spanish),
            detected: .identified(english, confidence: nil)
        )
        _ = body
        // Translation target is Spanish → no dictionary → hidden immediately.
        #expect(panel.translationPhoneticHiddenForTests == true)
    }

    @Test("Rendering an IPA string wraps it in slashes and shows the line")
    func renderShowsWrapped() {
        let panel = ResultPanel(phonetic: StubPhonetic(result: nil))
        let body = panel.buildResultBodyForTests(
            translation: "hello", source: "x",
            pair: LanguagePair(from: nil, to: english), detected: .unavailable
        )
        _ = body

        panel.renderPhoneticForTests(translation: true, ipa: "həˈloʊ")
        #expect(panel.translationPhoneticTextForTests == "/həˈloʊ/")
        #expect(panel.translationPhoneticHiddenForTests == false)

        // A nil transcription clears and hides the line.
        panel.renderPhoneticForTests(translation: true, ipa: nil)
        #expect(panel.translationPhoneticHiddenForTests == true)
    }
}

/// A canned `PhoneticProviding` for the panel tests (no bundle, no async work).
private struct StubPhonetic: PhoneticProviding {
    let result: String?
    func ipa(for text: String, languageCode: String?) async -> String? { result }
}
