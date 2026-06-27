import Foundation

/// One language in the translation catalog — the value type that generalizes
/// today's two-case `LanguageDirection.Target` (TECH §2). Every field feeds a
/// specific consumer; `aiName` is the single AI-capability source (`nil` ⇒ the
/// AI engine can't serve it, route Google), surfaced as `aiSupported`.
struct Language: Sendable, Identifiable, Hashable {
    /// Canonical BCP-47 code — the persisted value and the stable identity.
    let code: String
    /// English label, used in the picker and for search.
    let englishName: String
    /// Native-script name, shown in the picker and matched in search.
    let endonym: String
    /// The code Google's `sl=` / `tl=` params expect — diverges from `code`
    /// for some languages (he→iw, jv→jw, fil→tl).
    let googleCode: String
    /// Natural-language name fed to the OpenAI prompt; `nil` means the AI engine
    /// can't serve this language and the resolver routes it to Google.
    let aiName: String?
    /// Extra search terms (alternative names, romanizations, legacy codes).
    let aliases: [String]

    /// `code` is the identity (TECH §2 — "code == id").
    var id: String { code }

    /// True when the AI engine can serve this language (PM default: every
    /// language is AI-eligible for v1, so `aiName` is filled for all rows).
    var aiSupported: Bool { aiName != nil }

    init(
        code: String,
        englishName: String,
        endonym: String,
        googleCode: String,
        aiName: String?,
        aliases: [String]
    ) {
        self.code = code
        self.englishName = englishName
        self.endonym = endonym
        self.googleCode = googleCode
        self.aiName = aiName
        self.aliases = aliases
    }
}

/// A From/To selection. `from == nil` is the canonical representation of
/// Auto-detect everywhere (persisted as the `"auto"` sentinel). This is the one
/// shape the engine boundary, the guard, and the UI all agree on.
struct LanguagePair: Sendable, Equatable {
    /// Source language; `nil` means Auto-detect.
    var from: Language?
    /// Target language.
    var to: Language

    init(from: Language?, to: Language) {
        self.from = from
        self.to = to
    }
}
