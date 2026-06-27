import Foundation

/// The shared language catalog. `all` is generated from the canonical
/// `languages.tsv` (see `LanguageCatalog+Generated.swift` and
/// `scripts/gen-language-catalog.swift`); the lookups and search live here so
/// the generated file stays a pure data list.
enum LanguageCatalog {

    /// The canonical record for a BCP-47 `code` (the persisted value), or `nil`.
    static func language(forCode code: String) -> Language? {
        byCode[code]
    }

    /// The record whose Google `sl=`/`tl=` code matches — used to map a detected
    /// source (Google returns `iw`, `jw`, `zh-CN`, …) back to a canonical
    /// `Language`. Falls back to the canonical `code` so a value that is already
    /// canonical still resolves.
    static func language(forGoogleCode googleCode: String) -> Language? {
        byGoogleCode[googleCode] ?? byCode[googleCode]
    }

    /// Case- and diacritic-insensitive search over `englishName`, `endonym`,
    /// `code`, and `aliases`. Exact and prefix matches rank ahead of substring
    /// matches; ties keep catalog order. An empty query returns the whole list.
    static func search(_ query: String) -> [Language] {
        let needle = fold(query)
        guard !needle.isEmpty else { return all }

        let ranked = all.enumerated().compactMap { index, language -> (rank: Int, index: Int, language: Language)? in
            guard let rank = matchRank(language, needle: needle) else { return nil }
            return (rank, index, language)
        }
        return ranked
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.language)
    }

    // MARK: - Indexes

    private static let byCode: [String: Language] =
        Dictionary(all.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })

    private static let byGoogleCode: [String: Language] =
        Dictionary(all.map { ($0.googleCode, $0) }, uniquingKeysWith: { first, _ in first })

    // MARK: - Matching

    /// The best (lowest) match rank across a language's searchable fields, or
    /// `nil` when nothing matches: 0 = exact, 1 = prefix, 2 = substring.
    private static func matchRank(_ language: Language, needle: String) -> Int? {
        let haystacks = [language.englishName, language.endonym, language.code] + language.aliases
        var best: Int?
        for field in haystacks {
            let folded = fold(field)
            let rank: Int?
            if folded == needle {
                rank = 0
            } else if folded.hasPrefix(needle) {
                rank = 1
            } else if folded.contains(needle) {
                rank = 2
            } else {
                rank = nil
            }
            if let rank, rank < (best ?? Int.max) { best = rank }
        }
        return best
    }

    /// Normalizes a string for matching: case-, diacritic-, and width-insensitive.
    private static func fold(_ string: String) -> String {
        string.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
