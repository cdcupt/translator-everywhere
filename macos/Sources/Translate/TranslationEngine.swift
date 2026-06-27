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
/// Translation goes DIRECT to the engine — never through our server. The caller
/// hands the engine a `TranslationRequest` (text + the resolved From/To pair);
/// the engine returns a `TranslationResult` carrying the translation plus the
/// detected source and which engine served it. Direction is no longer the
/// engine's to guess — the resolved pair drives `sl`/`tl` (Google) and the
/// prompt (OpenAI). A `summarize` method joins this in the notebook slice.
protocol TranslationEngine: Sendable {
    /// Stable identity for the result badge.
    var kind: EngineKind { get }

    /// Translates `request.text` from `request.from` (or Auto when `nil`) into
    /// `request.to`, returning the translation plus detection metadata. Throws on
    /// a real failure (network, API error) so the caller can show an error state.
    func translate(_ request: TranslationRequest) async throws -> TranslationResult

    /// Produces a study-list summary of notebook `items`, client-side (PRD §5 —
    /// no server AI). The AI engine groups by theme with example sentences; the
    /// free engine, which can't summarize, returns a cleanly formatted list of
    /// the items ("free is simpler"). Throws on a real engine failure.
    func summarize(_ items: [VocabItem]) async throws -> String
}
