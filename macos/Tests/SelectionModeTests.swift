import Foundation
import Testing
@testable import Translator_Everywhere

/// Pure-function tests for the selection contract types (TECH §03·3, QA rows
/// U-01..U-16): the word/phrase ⇄ long-span threshold matrix, the span
/// normalizer, and the context window. No network, no seams — deterministic
/// matrices lifted straight from the spec's threshold table.
@Suite("Selection — mode threshold, normalizer, context window")
struct SelectionModeTests {

    // MARK: - U-01..U-11 · threshold matrix (TECH §03·3 table)

    @Test("U-01..U-11 · mode(for:) threshold matrix", arguments: [
        (id: "U-01", span: "scored", expected: SelectionMode.wordPhrase),      // AC-1 · FR-3 — 1 token
        (id: "U-02", span: "the final goal", expected: .wordPhrase),           // AC-2 · FR-3 — 3 tokens
        (id: "U-03", span: "kicked the winning goal", expected: .wordPhrase),  // FR-3 — boundary: exactly 4 tokens (≤ inclusive)
        (id: "U-04", span: "Messi scored the final goal.", expected: .longSpan), // AC-3 · FR-4 — 5 tokens
        (id: "U-05", span: "攻入", expected: .wordPhrase),                      // AC-9 · FR-3 — 2 Han graphemes, no whitespace
        (id: "U-06", span: "梅西攻入了最后一", expected: .wordPhrase),            // AC-9 · FR-3 — boundary: exactly 8 graphemes (≤ 8 inclusive)
        (id: "U-07", span: "梅西攻入了最后一球", expected: .longSpan),            // FR-4 · AC-9 — 9 graphemes
        (id: "U-08", span: "iPhone 攻略", expected: .wordPhrase),               // AC-9 edge — Han present ⇒ grapheme rule; 8 non-whitespace graphemes
        (id: "U-09", span: "안녕하세요 세계", expected: .wordPhrase),              // FR-3 — Hangul excluded from unspaced set ⇒ token rule, 2 tokens
        (id: "U-10", span: "  goal \n ", expected: .wordPhrase),               // FR-1 — normalize first, then count: 1 token
        (id: "U-11", span: "攻入 了", expected: .wordPhrase),                    // AC-9 — grapheme count skips whitespace: 3 graphemes
    ])
    func thresholdMatrix(row: (id: String, span: String, expected: SelectionMode)) {
        #expect(SelectionMode.mode(for: row.span) == row.expected, "\(row.id): \(row.span)")
    }

    // MARK: - U-12/U-13 · SpanNormalizer

    @Test("U-12 · normalize trims and folds whitespace runs incl. newlines; idempotent")
    func normalizeTrimsAndFolds() {
        let normalized = SpanNormalizer.normalize("  Messi\n  scored ")
        #expect(normalized == "Messi scored")
        // normalize ∘ normalize = normalize
        #expect(SpanNormalizer.normalize(normalized) == normalized)
    }

    @Test("U-13 · whitespace/newline-only span normalizes to empty")
    func normalizeWhitespaceOnlyIsEmpty() {
        #expect(SpanNormalizer.normalize("\n \t") == "")
    }

    // MARK: - U-14..U-16 · ContextWindow

    @Test("U-14 · context at or under the limit is returned verbatim")
    func windowShortContextVerbatim() {
        let short = "Messi scored the final goal in stoppage time."
        #expect(ContextWindow.window(for: "scored", in: short,
                                     maxChars: SelectionPolicy.maxContextChars) == short)

        // Boundary: exactly maxChars — still verbatim, untruncated.
        let exact = String(repeating: "a", count: SelectionPolicy.maxContextChars)
        #expect(ContextWindow.window(for: "a", in: exact,
                                     maxChars: SelectionPolicy.maxContextChars) == exact)
    }

    @Test("U-15 · long context: ≤ maxChars window containing the span, edges on whitespace")
    func windowLongContextContainsSpan() {
        // Unique tokens on both sides so a cut-off token at either edge is detectable.
        let before = (0..<300).map { "before\($0)" }.joined(separator: " ")
        let after = (0..<300).map { "after\($0)" }.joined(separator: " ")
        let span = "needle span"
        let context = before + " " + span + " " + after

        let window = ContextWindow.window(for: span, in: context,
                                          maxChars: SelectionPolicy.maxContextChars)

        #expect(window.count <= SelectionPolicy.maxContextChars)
        #expect(window.contains(span)) // span's first occurrence survives windowing

        // Edges land on whitespace boundaries: every window token is a whole
        // context token — a mid-token cut would produce a fragment not in the set.
        let contextTokens = Set(context.split(whereSeparator: \.isWhitespace))
        let windowTokens = window.split(whereSeparator: \.isWhitespace)
        #expect(!windowTokens.isEmpty)
        #expect(windowTokens.allSatisfy { contextTokens.contains($0) })

        // Centered, not a prefix: material survives on both sides of the span.
        #expect(windowTokens.contains { $0.hasPrefix("before") })
        #expect(windowTokens.contains { $0.hasPrefix("after") })
    }

    @Test("U-16 · span not found verbatim falls back to a prefix window; never crashes")
    func windowSpanNotFoundIsPrefixWindow() {
        let context = (0..<400).map { "tok\($0)" }.joined(separator: " ")
        let window = ContextWindow.window(for: "absent-needle", in: context,
                                          maxChars: SelectionPolicy.maxContextChars)

        #expect(window.count <= SelectionPolicy.maxContextChars)
        #expect(!window.isEmpty)
        #expect(context.hasPrefix(window))
    }

    // MARK: - withDeadline (S1 helper; service-level deadline behavior is I-06)

    private struct DeadlineMarker: Error {}

    @Test("withDeadline returns the operation's value when it beats the deadline")
    func withDeadlineFastPath() async throws {
        let value = try await withDeadline(.seconds(8), onTimeout: { DeadlineMarker() }) { "ok" }
        #expect(value == "ok")
    }

    @Test("withDeadline throws the injected timeout error when the deadline elapses first")
    func withDeadlineTimesOut() async {
        await #expect(throws: DeadlineMarker.self) {
            try await withDeadline(.milliseconds(20), onTimeout: { DeadlineMarker() }) {
                try await Task.sleep(for: .seconds(2)) // "hung" operation
                return "never"
            }
        }
    }
}
