import Foundation

/// OpenAI chat-completions engine using the user's own key (TECH §8.4).
///
/// Mirrors the `te` script: the same translator system prompt, model default
/// `gpt-4o-mini`, `temperature 0.2`, and `choices[0].message.content` parsing.
/// The key is read from `KeychainStore`; if absent the engine is not selectable
/// and the resolver falls back to Google (see `EngineResolver`).
struct OpenAIEngine: TranslationEngine {

    let kind: EngineKind = .ai

    /// Default model — overridable for a future Preferences toggle (slice 5).
    static let defaultModel = "gpt-4o-mini"

    /// Translator system prompt, lifted verbatim from the `te` script.
    static let systemPrompt = """
    You are a precise translator between English and Simplified Chinese. \
    Detect the input language: if it is mainly English, translate into natural Simplified Chinese; \
    if it is mainly Chinese, translate into natural, idiomatic English. \
    Preserve meaning, tone and any technical terms. Do not add quotes or commentary. \
    Output ONLY the translation, nothing else.
    """

    /// Study-list system prompt for `summarize`. Asks for theme grouping and a
    /// short example sentence per item — the richer output DESIGN §2c promises
    /// for the AI engine.
    static let summarizeSystemPrompt = """
    You are a language study coach. You are given a list of vocabulary captures, \
    each "source => translation". Produce a concise, well-structured Markdown \
    study list: group the items by theme with a short heading per group, and for \
    each item add one natural example sentence using it. Keep it tight and \
    practical. Output ONLY the Markdown study list, no preamble.
    """

    static let maxAttempts = 3
    static let retryDelay: Duration = .seconds(1)

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let retryDelay: Duration

    init(
        apiKey: String,
        model: String = OpenAIEngine.defaultModel,
        session: URLSession = .shared,
        retryDelay: Duration = OpenAIEngine.retryDelay
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.retryDelay = retryDelay
    }

    func translate(_ text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.emptyInput }

        let request = try makeRequest(text: trimmed)
        let data = try await fetchWithRetry(request)
        return try Self.parse(data)
    }

    /// Produces a real study-list summary: groups the captures by theme and adds
    /// an example sentence per item via the chat model (DESIGN §2c). Reuses the
    /// translate transport (same key, retries, parsing).
    func summarize(_ items: [VocabItem]) async throws -> String {
        guard !items.isEmpty else { throw TranslationError.emptyInput }
        let user = StudyListFormatter.promptLines(items)
        let request = try makeChatRequest(
            system: Self.summarizeSystemPrompt,
            user: user,
            temperature: 0.4
        )
        let data = try await fetchWithRetry(request)
        return try Self.parse(data)
    }

    // MARK: - Request

    /// Builds the translate POST request with the translator system prompt.
    /// Internal so tests can assert the body + headers.
    func makeRequest(text: String) throws -> URLRequest {
        try makeChatRequest(system: Self.systemPrompt, user: text, temperature: 0.2)
    }

    /// Shared chat-completions request builder for translate + summarize.
    func makeChatRequest(system: String, user: String, temperature: Double) throws -> URLRequest {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw TranslationError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ChatRequest(
            model: model,
            temperature: temperature,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user),
            ]
        )
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    private func fetchWithRetry(_ request: URLRequest) async throws -> Data {
        var lastError: Error = TranslationError.network(engine: .ai, underlying: nil)
        for attempt in 1...Self.maxAttempts {
            do {
                let (data, _) = try await session.data(for: request)
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

    /// Parses `choices[0].message.content`; surfaces `error.message` when the
    /// API returns an error envelope. Internal for unit tests.
    static func parse(_ data: Data) throws -> String {
        let decoder = JSONDecoder()
        if let response = try? decoder.decode(ChatResponse.self, from: data),
           let content = response.choices.first?.message.content,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) {
            throw TranslationError.api(message: envelope.error.message)
        }
        throw TranslationError.unexpectedResponse(engine: .ai)
    }

    // MARK: - Wire types

    private struct ChatRequest: Encodable {
        let model: String
        let temperature: Double
        let messages: [Message]

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    private struct ChatResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String }
    }

    private struct ErrorEnvelope: Decodable {
        let error: APIError
        struct APIError: Decodable { let message: String }
    }
}
