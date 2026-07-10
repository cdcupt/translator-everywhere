import Foundation

// Contextual-selection contract types and pure logic (TECH §03·1, §03·3).
// All selection value types live in this one cohesive file: no UI, no I/O.
// The service orchestration (`Translating.translateSelection`) consumes these
// in a later slice; nothing here touches an existing type.

/// The word/phrase dictionary-card payload (TECH §03·1).
///
/// `headword` is ALWAYS the user's normalized span — a model-echoed headword
/// is ignored (the selection is the source of truth; it is also what ⌘S saves).
struct DictionaryCard: Sendable, Equatable {
    let headword: String            // ALWAYS the user's normalized span — model echo is ignored
    let translation: String         // contextual translation (required; parse fails without it)
    let partOfSpeech: String?       // lowercase English tag ("verb", "noun phrase") — nil = row omitted
    let sense: String?              // one line, target language, in-context meaning
    let example: String?            // one NEW source-language sentence, same sense
    let exampleTranslation: String? // dropped if example == nil (never orphaned)
}

/// What a selection request produced: a dictionary card for a word/phrase, or
/// a plain translation block (long spans AND the degraded Google variant).
enum SelectionOutput: Sendable, Equatable {
    case card(DictionaryCard)       // dictionary card variant
    case plain(String)              // long-span block AND degraded variant
}

/// The value the selection seam returns: output plus the metadata the panel
/// renders (engine chip, "Context-free" chip when `contextUsed == false`).
struct SelectionResult: Sendable, Equatable {
    let output: SelectionOutput
    let servedBy: EngineKind        // .ai | .free — chip + notebook engine column
    let contextUsed: Bool           // false ⇒ "Context-free" chip (FR-5)
}

/// Gate-1 tunable constants for the selection feature (TECH §03·3).
enum SelectionPolicy {
    static let maxWordTokens = 4                         // spaced scripts (FR-3/FR-4)
    static let maxUnspacedGraphemes = 8                  // CJK / unspaced (AC-9)
    static let requestTimeout: Duration = .seconds(8)    // DESIGN §05 "request" row
    static let maxContextChars = 1500                    // PRD §08 "keep prompt small"
    static let settleDebounce: Duration = .milliseconds(300)  // consumed by the UI layer
    /// The panel-side outer net (beta round 2, F1): if NO outcome reaches the
    /// slot by the request deadline + grace — a lookup hung *below* the
    /// service's own deadline (blocking Keychain read, unresumed continuation)
    /// or an outcome mis-mapped into the void — the slot renders the quiet
    /// error row instead of shimmering forever.
    static let watchdogTimeout: Duration = requestTimeout + .milliseconds(500)
}

/// Folds whitespace runs (including newlines) to a single space and trims.
/// Identical-span dedupe and the mode threshold both key on this. Idempotent.
enum SpanNormalizer {
    static func normalize(_ span: String) -> String {
        span.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Word/phrase ⇄ long-span classification — a pure function of the span alone
/// (TECH §03·3, Fig. B3). Grapheme counting is Swift's native `String.count`
/// (extended grapheme clusters), so composed characters and emoji count as one.
enum SelectionMode: Sendable, Equatable {
    case wordPhrase, longSpan

    static func mode(for span: String) -> SelectionMode {
        let s = SpanNormalizer.normalize(span)
        if s.unicodeScalars.contains(where: Self.isUnspacedScript) {
            let graphemes = s.filter { !$0.isWhitespace }.count      // grapheme clusters
            return graphemes <= SelectionPolicy.maxUnspacedGraphemes ? .wordPhrase : .longSpan
        }
        let tokens = s.split(whereSeparator: \.isWhitespace).count
        return tokens <= SelectionPolicy.maxWordTokens ? .wordPhrase : .longSpan
    }

    /// Scripts written without word-delimiting whitespace, so token counting is
    /// meaningless and the grapheme rule applies. Hangul is deliberately
    /// excluded — Korean is whitespace-delimited.
    private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,       // Han — CJK Extension A
             0x4E00...0x9FFF,       // Han — CJK Unified Ideographs
             0xF900...0xFAFF,       // Han — CJK Compatibility Ideographs
             0x20000...0x2EBEF,     // Han — CJK Extensions B–F
             0x3040...0x309F,       // Hiragana
             0x30A0...0x30FF,       // Katakana
             0x31F0...0x31FF,       // Katakana Phonetic Extensions
             0xFF66...0xFF9D,       // Halfwidth Katakana
             0x0E00...0x0E7F,       // Thai
             0x0E80...0x0EFF,       // Lao
             0x1780...0x17FF,       // Khmer
             0x1000...0x109F:       // Myanmar
            return true
        default:
            return false
        }
    }
}

/// Windows the recognized text so the prompt stays small (PRD §08): the full
/// context when it fits `maxChars`, else a window centered on the span's first
/// occurrence; a prefix window when the span isn't found verbatim.
enum ContextWindow {
    static func window(for span: String, in context: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        guard context.count > maxChars else { return context }
        guard !span.isEmpty, let spanRange = context.range(of: span) else {
            return String(context.prefix(maxChars))
        }

        let spanLength = context.distance(from: spanRange.lowerBound, to: spanRange.upperBound)
        guard spanLength < maxChars else {
            return String(context[spanRange].prefix(maxChars))
        }

        // Center the window on the span, redistributing unused budget from a
        // short side to the other so the window always spends its maxChars.
        let budget = maxChars - spanLength
        let beforeAvailable = context.distance(from: context.startIndex, to: spanRange.lowerBound)
        let afterAvailable = context.distance(from: spanRange.upperBound, to: context.endIndex)
        let after = min(afterAvailable, budget - min(beforeAvailable, budget / 2))
        let before = min(beforeAvailable, budget - after)

        var lower = context.index(spanRange.lowerBound, offsetBy: -before)
        var upper = context.index(spanRange.upperBound, offsetBy: after)

        // Snap a mid-token leading edge forward to the next whitespace (never
        // past the span) so the window starts on a whole token.
        if lower != context.startIndex, !context[context.index(before: lower)].isWhitespace {
            while lower < spanRange.lowerBound, !context[lower].isWhitespace {
                lower = context.index(after: lower)
            }
        }
        // Snap a mid-token trailing edge backward likewise (never into the span).
        if upper != context.endIndex, !context[upper].isWhitespace {
            while upper > spanRange.upperBound, !context[context.index(before: upper)].isWhitespace {
                upper = context.index(before: upper)
            }
        }

        return String(context[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The engine route the resolver picks for a selection (TECH §03·1).
enum SelectionRoute {
    case contextual(any SelectionSpanTranslating)   // OpenAI: span + context prompt
    case contextFree(any TranslationEngine)         // Google: span-only, degraded
}

/// Selection capability — adopted by OpenAIEngine ONLY. Google is never asked
/// to do something it can't (`TranslationEngine` stays untouched).
protocol SelectionSpanTranslating: Sendable {
    func translateSpan(span: String, context: String,
                       pair: LanguagePair, mode: SelectionMode) async throws -> SelectionOutput
}

/// Races `operation` against `timeout` in a structured task group (TECH §03·2,
/// Fig. B2). If the deadline elapses first the group cancels the operation
/// child (its retry loops observe `Task.checkCancellation()`) and the caller's
/// timeout error is thrown. An outer cancellation surfaces as
/// `CancellationError`, rethrown as-is — provably distinct from a timeout.
func withDeadline<T: Sendable>(
    _ timeout: Duration,
    onTimeout makeTimeoutError: @escaping @Sendable () -> any Error,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil // deadline child: an intact sleep means the timeout elapsed
        }
        defer { group.cancelAll() }
        // The first child to finish decides the race: a value wins; the deadline
        // child's nil means the timeout won; any throw — including an outer
        // CancellationError — is rethrown untouched.
        guard let winner = try await group.next(), let value = winner else {
            throw makeTimeoutError()
        }
        return value
    }
}
