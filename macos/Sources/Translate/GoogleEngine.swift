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

    func translate(_ text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.emptyInput }

        let target = LanguageDirection.target(for: trimmed)
        let request = try Self.makeRequest(text: trimmed, target: target)

        let data = try await fetchWithRetry(request)
        guard let translated = Self.parse(data) else {
            throw TranslationError.unexpectedResponse(engine: .free)
        }
        return translated
    }

    /// The free engine can't summarize, so — by design ("free is simpler") — it
    /// returns a cleanly formatted list of the items rather than a synthesized
    /// study list. No network call. See `StudyListFormatter`.
    func summarize(_ items: [VocabItem]) async throws -> String {
        StudyListFormatter.plainList(items)
    }

    // MARK: - Request

    /// Builds the GET request. Exposed (internal) so tests can assert the URL.
    static func makeRequest(text: String, target: LanguageDirection.Target) throws -> URLRequest {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target.googleCode),
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

    /// Parses Google's nested array response and joins the translated segments.
    ///
    /// Shape: `[[ ["译文","src",...], ["seg2","src2",...] ], ...]` — we join the
    /// first element of each segment in `json[0]`. Exposed for unit tests.
    static func parse(_ data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
            let segments = root.first as? [Any]
        else {
            return nil
        }

        let joined = segments
            .compactMap { ($0 as? [Any])?.first as? String }
            .joined()

        return joined.isEmpty ? nil : joined
    }
}
