import Foundation

/// Which concrete engine produced a translation — drives the result badge.
enum EngineKind: String, Sendable {
    case free   // Google free endpoint, keyless.
    case ai     // OpenAI with the user's key.

    /// Short uppercase label for the result panel badge.
    var badge: String {
        switch self {
        case .free: return "FREE"
        case .ai: return "AI"
        }
    }
}

/// A translation backend (TECH §8.4).
///
/// Translation goes DIRECT to the engine — never through our server. Each engine
/// auto-detects direction (mostly-Chinese → English, else → Simplified Chinese);
/// the caller supplies only the source text. A `summarize` method joins this in
/// the notebook slice — not now.
protocol TranslationEngine: Sendable {
    /// Stable identity for the result badge.
    var kind: EngineKind { get }

    /// Translates `text`, auto-detecting the target language. Throws on a real
    /// failure (network, API error) so the caller can show an error state.
    func translate(_ text: String) async throws -> String
}

/// Auto target-language detection, mirroring the `te` script's `is_chinese`:
/// if the text is *mostly* Han characters translate to English, otherwise to
/// Simplified Chinese.
enum LanguageDirection {

    /// BCP-47 target for Google's `tl` param and OpenAI direction hints.
    static func target(for text: String) -> Target {
        isMostlyChinese(text) ? .english : .simplifiedChinese
    }

    /// True when Han characters outnumber other letters — robust to a stray
    /// ASCII word inside a Chinese sentence (the `te` script keys off *any* Han,
    /// but "mostly" avoids flipping on a single embedded Chinese term).
    static func isMostlyChinese(_ text: String) -> Bool {
        var han = 0
        var letters = 0
        for scalar in text.unicodeScalars {
            if isHan(scalar) {
                han += 1
                letters += 1
            } else if CharacterSet.letters.contains(scalar) {
                letters += 1
            }
        }
        guard letters > 0 else { return false }
        return han * 2 >= letters
    }

    /// CJK Unified Ideographs (incl. common extensions) — the `\p{Han}` script.
    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,   // Ext A
             0x4E00...0x9FFF,   // Unified
             0xF900...0xFAFF,   // Compatibility Ideographs
             0x20000...0x2A6DF, // Ext B
             0x2A700...0x2EBEF: // Ext C–F
            return true
        default:
            return false
        }
    }

    /// A supported translation target.
    enum Target {
        case english
        case simplifiedChinese

        /// BCP-47 code for Google's `tl` query parameter.
        var googleCode: String {
            switch self {
            case .english: return "en"
            case .simplifiedChinese: return "zh-CN"
            }
        }
    }
}
