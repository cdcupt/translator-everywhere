import Foundation

/// Free Google Translate engine — keyless, the default (TECH §8.4).
///
/// Hits `translate.googleapis.com/translate_a/single` with the same params as the
/// `te` script (`client=gtx, sl=auto, tl=<auto>, dt=t, q=<text>`), parses the
/// nested array response, and joins the translated segments. Transient failures
/// retry with a short back-off, like `te`.
struct GoogleEngine: TranslationEngine {

    let kind: EngineKind = .free

    /// Total attempts on transient failure (matches `te`'s 1..3 loop).
    static let maxAttempts = 3

    /// Back-off between attempts.
    static let retryDelay: Duration = .seconds(1)

    private let session: URLSession
    private let retryDelay: Duration

    init(session: URLSession = .shared, retryDelay: Duration = GoogleEngine.retryDelay) {
        self.session = session
        self.retryDelay = retryDelay
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.emptyInput }

        // The resolved pair drives the call: explicit From → its Google code,
        // Auto → "auto" (Google detects and reports the source in the response).
        let sl = request.from?.googleCode ?? "auto"
        let tl = request.to.googleCode
        let urlRequest = try Self.makeRequest(text: trimmed, sourceCode: sl, targetCode: tl)

        let data = try await fetchWithRetry(urlRequest)
        guard let parsed = Self.parse(data) else {
            throw TranslationError.unexpectedResponse(engine: .free)
        }
        return TranslationResult(
            translation: parsed.translation,
            detected: Self.detectedSource(from: parsed.detectedCode),
            servedBy: .free,
            // The engine never owns the "via Google" signal — the resolver does
            // (TECH §4); a self-contained Google call is always plain FREE.
            viaGoogleFallback: false
        )
    }

    /// The free engine can't summarize, so — by design ("free is simpler") — it
    /// returns a cleanly formatted list of the items rather than a synthesized
    /// study list. No network call. See `StudyListFormatter`.
    func summarize(_ items: [VocabItem]) async throws -> String {
        StudyListFormatter.plainList(items)
    }

    // MARK: - Request

    /// Builds the GET request. Exposed (internal) so tests can assert the URL.
    static func makeRequest(text: String, sourceCode: String, targetCode: String) throws -> URLRequest {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: sourceCode),
            URLQueryItem(name: "tl", value: targetCode),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let url = components?.url else {
            throw TranslationError.invalidRequest
        }
        return URLRequest(url: url)
    }

    private func fetchWithRetry(_ request: URLRequest) async throws -> Data {
        var lastError: Error = TranslationError.network(engine: .free, underlying: nil)
        for attempt in 1...Self.maxAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw TranslationError.network(engine: .free, underlying: nil)
                }
                return data
            } catch {
                try Task.checkCancellation() // don't retry a cancelled task
                lastError = error
                if attempt < Self.maxAttempts {
                    try? await Task.sleep(for: retryDelay)
                }
            }
        }
        throw lastError
    }

    // MARK: - Parsing

    /// The two pieces a single Google call yields: the joined translation and the
    /// detected source code (Google's `sl`, e.g. `iw`, `zh-CN`), `nil` when the
    /// response carries no usable source.
    struct ParsedResponse: Equatable {
        let translation: String
        let detectedCode: String?
    }

    /// Parses Google's nested array response into the joined translation plus the
    /// detected source code.
    ///
    /// Shape: `[[ ["译文","src",...], ... ], ..., "<detected>", ...]` — we join the
    /// first element of each segment in `root[0]` and read the detected source
    /// from `root[2]` (fallback `root[8][0][0]`). Returns `nil` only when there is
    /// no translation. Exposed for unit tests.
    static func parse(_ data: Data) -> ParsedResponse? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
            let segments = root.first as? [Any]
        else {
            return nil
        }

        let joined = segments
            .compactMap { ($0 as? [Any])?.first as? String }
            .joined()
        guard !joined.isEmpty else { return nil }

        return ParsedResponse(translation: joined, detectedCode: detectedCode(in: root))
    }

    /// The detected source code: `root[2]` (a Google `sl` string), falling back
    /// to `root[8][0][0]` if that shape shifts. `nil` when neither is present.
    static func detectedCode(in root: [Any]) -> String? {
        if root.count > 2, let code = root[2] as? String, !code.isEmpty {
            return code
        }
        if root.count > 8,
           let langId = root[8] as? [Any],
           let first = langId.first as? [Any],
           let code = first.first as? String,
           !code.isEmpty {
            return code
        }
        return nil
    }

    /// Maps a detected Google code back to a catalog `Language`. No code present
    /// → `.uncertain` (locked default #3 — suppress the guard, never a wrong
    /// flip); a code the catalog can't place → `.unavailable`. Confidence is not
    /// surfaced here (the boundary carries `nil`).
    static func detectedSource(from code: String?) -> DetectedSource {
        guard let code, !code.isEmpty else { return .uncertain }
        guard let language = LanguageCatalog.language(forGoogleCode: code) else {
            return .unavailable
        }
        return .identified(language, confidence: nil)
    }
}
