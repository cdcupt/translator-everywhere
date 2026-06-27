import Foundation

/// The source language detection outcome for a translation (TECH §3).
///
/// `.identified` carries the detected `Language` and Google's optional
/// confidence. `.uncertain` means detection ran but produced no usable source
/// (the guard is suppressed so a wrong flip is impossible). `.unavailable`
/// means detection could not run at all (also suppresses the guard).
enum DetectedSource: Sendable, Equatable {
    case identified(Language, confidence: Double?)
    case uncertain
    case unavailable

    /// The detected language's canonical code when `.identified`, else `nil`.
    /// Used to thread the source code into the notebook row (`srcLang`).
    var languageCode: String? {
        if case let .identified(language, _) = self { return language.code }
        return nil
    }
}

/// What the caller hands the engine boundary: the text plus the resolved pair.
/// `from == nil` means Auto-detect (the engine/orchestrator detects the source).
struct TranslationRequest: Sendable {
    let text: String
    let from: Language?
    let to: Language

    init(text: String, from: Language?, to: Language) {
        self.text = text
        self.from = from
        self.to = to
    }
}

/// What the engine boundary returns: the translation plus the metadata the
/// result surface renders (detected source, which engine served it, and whether
/// an AI-preferred request was routed to Google).
struct TranslationResult: Sendable {
    let translation: String
    let detected: DetectedSource
    let servedBy: EngineKind
    /// Explicit, not inferred from `servedBy`: distinguishes a plain no-key FREE
    /// result from an AI-preferred pair that fell back to Google (TECH §4).
    let viaGoogleFallback: Bool

    init(
        translation: String,
        detected: DetectedSource,
        servedBy: EngineKind,
        viaGoogleFallback: Bool
    ) {
        self.translation = translation
        self.detected = detected
        self.servedBy = servedBy
        self.viaGoogleFallback = viaGoogleFallback
    }
}

/// The engine the resolver picked for a pair, plus the authoritative
/// "via Google" signal (TECH §4). The concrete wiring that produces this lands
/// in the resolver slice; this is the value type the boundary agrees on.
struct ResolvedEngine {
    let engine: any TranslationEngine
    let viaGoogleFallback: Bool

    init(engine: any TranslationEngine, viaGoogleFallback: Bool) {
        self.engine = engine
        self.viaGoogleFallback = viaGoogleFallback
    }
}
