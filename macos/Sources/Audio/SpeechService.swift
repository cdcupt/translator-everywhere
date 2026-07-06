import AVFoundation

/// Read-aloud (text-to-speech) for the result panel — the "🔈" speaker buttons
/// on the Translation / Recognized panes, mirroring Google Translate.
///
/// The seam `ResultPanel` depends on (like `ResultPresenting`) so the speaker
/// wiring can be unit-tested with a spy: which text and BCP-47 language a tap
/// hands the synthesizer, and whether a button is offered at all for a language
/// the system can't voice. `SpeechService` is the production, `AVFoundation`-
/// backed conformer.
@MainActor
protocol SpeechSynthesizing: AnyObject {
    /// Speaks `text` in the voice for `languageCode` (a catalog BCP-47 code, e.g.
    /// `"en"`, `"zh-CN"`). A `nil`/unknown code falls back to the system default
    /// voice. Interrupts anything already speaking. No-op for empty text.
    func speak(_ text: String, languageCode: String?)
    /// Stops any in-progress utterance immediately.
    func stop()
    /// Whether the system has a voice that can read `languageCode`. The panel uses
    /// this to hide the speaker button for languages with no installed voice
    /// (e.g. Aymara, Bhojpuri) instead of offering a button that says nothing.
    func canSpeak(languageCode: String?) -> Bool
    /// Invoked on the main actor when an utterance ends on its own (not via an
    /// interrupting `speak`/`stop`), so the panel can reset the speaker icon from
    /// "stop" back to "speaker".
    var onFinish: (@MainActor () -> Void)? { get set }
}

/// Native `AVSpeechSynthesizer` read-aloud: offline, free, and no entitlement —
/// the app runs unsandboxed, and speech *playback* (unlike recording) needs no
/// audio permission. Voices are matched by BCP-47 code against the set the
/// system actually has installed (`SpeechVoiceResolver`), so what the button
/// offers and what it speaks always agree.
@MainActor
final class SpeechService: NSObject, SpeechSynthesizing {

    var onFinish: (@MainActor () -> Void)?

    private let synthesizer: AVSpeechSynthesizer

    /// The language tags the system can voice (e.g. `"en-US"`, `"zh-CN"`),
    /// deduplicated. Read once — the installed voice set doesn't change over a
    /// session.
    private let availableTags: [String]

    /// The utterance currently owned by this service. Held so a natural
    /// `didFinish`/`didCancel` can be told apart from the `didCancel` produced
    /// when a new `speak` interrupts the previous one: only the *current*
    /// utterance's completion resets state. Compared by identity.
    private var currentUtterance: AVSpeechUtterance?

    init(
        synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer(),
        availableTags: [String] = SpeechService.installedVoiceTags()
    ) {
        self.synthesizer = synthesizer
        self.availableTags = availableTags
        super.init()
        self.synthesizer.delegate = self
    }

    /// The deduplicated language tags of every installed voice, sorted so the
    /// pure resolver's fallback is deterministic. `nonisolated` so it can seed the
    /// `init` default argument (evaluated off the main actor);
    /// `AVSpeechSynthesisVoice.speechVoices()` is safe from any thread.
    nonisolated static func installedVoiceTags() -> [String] {
        Array(Set(AVSpeechSynthesisVoice.speechVoices().map(\.language))).sorted()
    }

    func canSpeak(languageCode: String?) -> Bool {
        resolveVoice(for: languageCode) != nil
    }

    func speak(_ text: String, languageCode: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = resolveVoice(for: languageCode)

        // Claim identity *before* interrupting: the interrupted utterance's
        // `didCancel` then fails the `=== currentUtterance` guard and is ignored,
        // so switching panes mid-read doesn't clear the freshly-started state.
        currentUtterance = utterance
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthesizer.speak(utterance)
    }

    func stop() {
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// The voice to read `code` in. `AVSpeechSynthesisVoice(language:)` is Apple's
    /// own resolver: it maps a bare code to a sensible default region ("en" →
    /// en-US, not an arbitrary accent), resolves macrolanguages ("no" → nb-NO),
    /// and returns `nil` for a language with no installed voice — exactly the
    /// availability signal the speaker button needs. The pure `SpeechVoiceResolver`
    /// is a deterministic fallback (and the unit-tested core) for any code Apple
    /// doesn't resolve directly.
    private func resolveVoice(for code: String?) -> AVSpeechSynthesisVoice? {
        guard let code, !code.isEmpty else { return nil }
        if let voice = AVSpeechSynthesisVoice(language: code) { return voice }
        if let tag = SpeechVoiceResolver.match(code: code, available: availableTags) {
            return AVSpeechSynthesisVoice(language: tag)
        }
        return nil
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        finished(utterance)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        finished(utterance)
    }

    /// Hops to the main actor and fires `onFinish` only for the utterance the
    /// service still owns (identity via `ObjectIdentifier`, which is `Sendable` —
    /// the utterance itself isn't). A cancel from an interrupting `speak`/`stop`
    /// no longer matches `currentUtterance` and is dropped.
    private nonisolated func finished(_ utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.currentUtterance,
                  ObjectIdentifier(current) == id else { return }
            self.currentUtterance = nil
            self.onFinish?()
        }
    }
}

/// Pure BCP-47 → installed-voice-tag matcher, split out so voice selection is
/// unit-testable without audio or a specific machine's installed voice set.
///
/// The catalog codes are primary subtags (`"en"`, `"ar"`) plus a few regioned
/// ones (`"zh-CN"`, `"zh-TW"`); the system exposes regioned tags (`"en-US"`,
/// `"pt-BR"`). Matching is: exact (case-insensitive), then same primary subtag.
enum SpeechVoiceResolver {
    /// The best available voice tag for `code`, or `nil` when nothing matches
    /// (the caller hides the speaker button). `available` is the set of installed
    /// voice language tags.
    /// Macrolanguage / legacy-code aliases where the catalog's primary subtag
    /// differs from the installed voice's (Norwegian `"no"` ↔ Bokmål `"nb-NO"`).
    /// Keeps the pure matcher correct even without deferring to Apple's resolver.
    private static let primaryAliases: [String: String] = ["no": "nb"]

    static func match(code: String?, available: [String]) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let wanted = code.lowercased()

        // 1. Exact tag (e.g. "zh-CN" → "zh-CN"), case-insensitive.
        if let exact = available.first(where: { $0.lowercased() == wanted }) {
            return exact
        }

        // 2. Same (aliased) primary subtag (e.g. "en" → "en-US", "pt" → "pt-BR",
        //    "no" → "nb-NO"). Also lets a regioned request degrade to another
        //    region of the same language if its exact region isn't installed.
        let wantedPrimary = canonicalPrimary(wanted)
        return available.first { canonicalPrimary($0.lowercased()) == wantedPrimary }
    }

    private static func canonicalPrimary(_ tag: String) -> String {
        let primary = primarySubtag(tag)
        return primaryAliases[primary] ?? primary
    }

    private static func primarySubtag(_ tag: String) -> String {
        String(tag.split(separator: "-").first ?? Substring(tag))
    }
}
