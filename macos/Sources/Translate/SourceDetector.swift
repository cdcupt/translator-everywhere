import Foundation

/// The shared, keyless source-language detector (TECH §3).
///
/// Runs a single Google `translate_a/single` call (`sl=auto`) and reads the
/// detected source from the response, reusing `GoogleEngine`'s parsing (`root[2]`,
/// fallback `root[8][0][0]`). Engine-independent on purpose: the orchestrator
/// detects once, up front, so the detected source is authoritative on *both* the
/// Google and the AI translate paths — closing slice-3's AI-path `.unavailable`
/// gap (the AI engine no longer has to guess the source itself).
struct SourceDetector {

    private let session: URLSession

    /// Any valid target works — detection is read from the response's `root[2]`
    /// regardless of `tl`. English keeps the probe response small.
    private static let probeTargetCode = "en"

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Detects the source language of `text`:
    /// - `.identified` when Google reports a code the catalog can place,
    /// - `.uncertain` when the call ran but reported no usable source (guard
    ///   suppressed — never a wrong flip),
    /// - `.unavailable` when the detect call itself can't run (empty input, bad
    ///   request, network/parse failure) — also suppresses the guard.
    func detect(_ text: String) async -> DetectedSource {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            let request = try? GoogleEngine.makeRequest(
                text: trimmed, sourceCode: "auto", targetCode: Self.probeTargetCode
            ),
            let (data, _) = try? await session.data(for: request),
            let parsed = GoogleEngine.parse(data)
        else {
            return .unavailable
        }
        return GoogleEngine.detectedSource(from: parsed.detectedCode)
    }
}
