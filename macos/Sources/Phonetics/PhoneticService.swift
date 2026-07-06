import Foundation

/// Read-side seam for the IPA phonetic line (音标) shown under an English result
/// pane. Async so the production service can lazily load its ~125k-word
/// dictionary off the main actor on first use; a spy conforms in tests.
protocol PhoneticProviding: Sendable {
    /// The IPA transcription of `text` when `languageCode` is English and at
    /// least one word is known, else `nil` (the panel then shows no line). The
    /// returned string is the bare phoneme line — the caller wraps it in `/ … /`.
    func ipa(for text: String, languageCode: String?) async -> String?
}

/// Native, offline English IPA lookup. Loads a bundled word→IPA dictionary
/// (`english-ipa.txt`, derived from the MIT-licensed ipa-dict — see
/// `Resources/THIRD-PARTY.md`) once, lazily, then transcribes word-by-word via
/// the pure `PhoneticTranscriber`. English-only: other languages have no
/// dictionary here and return `nil`, which is why the panel only offers the line
/// on English panes.
actor PhoneticService: PhoneticProviding {

    private var dictionary: [String: String]?
    private let loader: @Sendable () -> [String: String]

    init(loader: @escaping @Sendable () -> [String: String] = { PhoneticService.loadBundledDictionary() }) {
        self.loader = loader
    }

    func ipa(for text: String, languageCode: String?) async -> String? {
        guard PhoneticLanguage.isEnglish(languageCode) else { return nil }
        return PhoneticTranscriber.transcribe(text, dictionary: loadedDictionary())
    }

    /// Loads (and caches) the dictionary on first use.
    private func loadedDictionary() -> [String: String] {
        if let dictionary { return dictionary }
        let loaded = loader()
        dictionary = loaded
        return loaded
    }

    /// Parses the bundled `english-ipa.txt` (`word<TAB>ipa` per line) into a map.
    /// Returns an empty map if the resource is missing so the feature degrades to
    /// "no phonetic line" rather than crashing.
    static func loadBundledDictionary() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "english-ipa", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }

        var map: [String: String] = [:]
        map.reserveCapacity(130_000)
        text.enumerateLines { line, _ in
            guard let tab = line.firstIndex(of: "\t") else { return }
            let word = String(line[..<tab])
            let ipa = String(line[line.index(after: tab)...])
            if !word.isEmpty, !ipa.isEmpty { map[word] = ipa }
        }
        return map
    }
}

/// The English gate for the phonetic line — pure so it's testable and shared by
/// the service and the panel.
enum PhoneticLanguage {
    /// True for the canonical `"en"` or any regioned `"en-*"` (case-insensitive).
    static func isEnglish(_ code: String?) -> Bool {
        guard let code = code?.lowercased() else { return false }
        return code == "en" || code.hasPrefix("en-")
    }
}

/// Pure word-by-word IPA assembly, split out so it's unit-testable without the
/// bundle or a specific dictionary. Tokenizes on whitespace, strips edge
/// punctuation (phonetic lines omit it), looks each word up case-insensitively
/// (curly apostrophes folded to straight to match the dictionary's `it's`
/// forms), and joins with spaces. Unknown words are kept as their bare
/// lowercased form so the line still reads left-to-right; `nil` is returned when
/// *no* word is known, so the panel shows nothing rather than a line of raw text.
enum PhoneticTranscriber {
    static func transcribe(_ text: String, dictionary: [String: String]) -> String? {
        // Break on all Unicode whitespace (NBSP, ideographic space, etc. — common
        // in pasted/OCR'd text) plus the separators that glue words without spaces
        // — slash ("and/or") and em/en dashes ("end—finally") — so both sides get
        // transcribed instead of failing as one unknown token.
        let tokens = text.split { char in
            char.isWhitespace || char == "/" || char == "\u{2014}" || char == "\u{2013}"
        }
        var pieces: [String] = []
        var anyKnown = false

        for token in tokens {
            let key = normalizedKey(strippedCore(String(token)))
            guard !key.isEmpty else { continue }   // pure-punctuation token

            if let ipa = dictionary[key] {
                anyKnown = true
                pieces.append(ipa)
            } else if key.hasSuffix("'"), let ipa = dictionary[String(key.dropLast())] {
                // A quoted plain word (‘hello’ → key "hello'") — retry without the
                // trailing quote-apostrophe. Real possessives ("actors'") hit on
                // the first lookup, so this only fires for genuine misses.
                anyKnown = true
                pieces.append(ipa)
            } else {
                // Keep the unknown word, but strip stray edge apostrophes/hyphens
                // (and drop a token that is only those) so the line stays clean.
                let bare = key.trimmingCharacters(in: Self.edgeMarks)
                if !bare.isEmpty { pieces.append(bare) }
            }
        }

        guard anyKnown else { return nil }
        return pieces.joined(separator: " ")
    }

    /// Apostrophes/hyphens trimmed from an unknown word before it's shown bare.
    private static let edgeMarks = CharacterSet(charactersIn: "'-")

    /// Trims leading/trailing characters that aren't part of a word (quotes,
    /// brackets, punctuation), keeping letters, numbers, and word-internal
    /// apostrophes/hyphens.
    private static func strippedCore(_ token: String) -> String {
        let isWordChar: (Character) -> Bool = {
            $0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}" || $0 == "-"
        }
        let chars = Array(token)
        var start = 0
        var end = chars.count
        while start < end, !isWordChar(chars[start]) { start += 1 }
        while end > start, !isWordChar(chars[end - 1]) { end -= 1 }
        return String(chars[start..<end])
    }

    /// Lowercases and folds the curly apostrophe to straight so `it's`/`it’s`
    /// both hit the dictionary key.
    private static func normalizedKey(_ core: String) -> String {
        core.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }
}
