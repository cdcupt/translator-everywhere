import Foundation

/// The same-language guard, isolated as a pure function so the S5 EN⇄ZH
/// regression surface is deterministic and unit-testable (TECH §3). It replaces
/// `LanguageDirection.target(for:)` and the in-store Han-flip derivation.
///
/// The guard preserves the old two-language flip: when From is Auto and the
/// detected source is the chosen target, translate to the secondary language
/// instead (e.g. home = 中文, capture Chinese → detected zh == to → flip to en).
enum PairResolver {

    /// The effective target after applying the same-language guard.
    ///
    /// The guard fires **only** when all hold:
    /// - `pair.from == nil` (Auto — an explicit From bypasses the guard), and
    /// - `detected` is `.identified` with a code equal to `pair.to.code`, and
    /// - a `secondary` exists that is distinct from `pair.to`.
    ///
    /// Otherwise the target stays `pair.to`. Detection that is `.uncertain` or
    /// `.unavailable` suppresses the guard (no flip), so a wrong flip on weak
    /// detection is impossible.
    static func effectiveTo(
        detected: DetectedSource,
        pair: LanguagePair,
        secondary: Language?
    ) -> Language {
        // Explicit From bypasses the guard entirely.
        guard pair.from == nil else { return pair.to }

        // Only a confident identification can trigger a flip; uncertain /
        // unavailable detection is suppressed.
        guard case let .identified(source, _) = detected else { return pair.to }

        // No collision — detected source differs from the chosen target.
        guard source.code == pair.to.code else { return pair.to }

        // Need a distinct secondary to flip to; otherwise fall through to `to`.
        guard let secondary, secondary.code != pair.to.code else { return pair.to }

        return secondary
    }
}
