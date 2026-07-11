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

    /// Builds the translator system prompt for the requested pair, parameterized
    /// from the catalog's `aiName` (TECH §3). With an explicit From it names both
    /// languages; with Auto (`from == nil`) it asks the model to detect the source
    /// and translate into the target. Mirrors `te`'s instruction style (preserve
    /// meaning/tone, output only the translation). `aiName` is `nil` only for
    /// AI-incapable pairs the resolver routes to Google up front, so the
    /// `englishName` fallback is purely defensive.
    static func systemPrompt(from: Language?, to: Language) -> String {
        let target = to.aiName ?? to.englishName
        let lead: String
        if let from {
            let source = from.aiName ?? from.englishName
            lead = "You are a precise translator. Translate the input from \(source) "
                + "into natural, idiomatic \(target)."
        } else {
            lead = "You are a precise translator. Detect the input language and "
                + "translate it into natural, idiomatic \(target)."
        }
        return lead + " Preserve meaning, tone and any technical terms. "
            + "Do not add quotes or commentary. Output ONLY the translation, nothing else."
    }

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

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.emptyInput }

        let urlRequest = try makeRequest(for: request, text: trimmed)
        let data = try await fetchWithRetry(urlRequest)
        let content = try Self.parse(data)
        return TranslationResult(
            translation: content,
            // With an explicit From we echo it; with Auto, the AI path's real
            // source detection is slice 6's job (orchestration), so detection is
            // `.unavailable` here — which suppresses the guard upstream.
            detected: request.from.map { .identified($0, confidence: nil) } ?? .unavailable,
            servedBy: .ai,
            viaGoogleFallback: false,
            effectiveTo: request.to
        )
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

    /// Builds the translate POST request with the pair-parameterized translator
    /// prompt. Internal so tests can assert the body + headers.
    func makeRequest(for request: TranslationRequest, text: String) throws -> URLRequest {
        let system = Self.systemPrompt(from: request.from, to: request.to)
        return try makeChatRequest(system: system, user: text, temperature: 0.2)
    }

    /// Shared chat-completions request builder for translate + summarize +
    /// selection. `responseFormat` opts the card variant into JSON mode
    /// (TECH §03·2); when nil the key is omitted from the wire body entirely.
    func makeChatRequest(
        system: String,
        user: String,
        temperature: Double,
        responseFormat: ResponseFormat? = nil
    ) throws -> URLRequest {
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
            ],
            responseFormat: responseFormat
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

    /// Optional chat-completions `response_format`. Encodes as
    /// `{"type": "json_object"}` (JSON mode — supported by gpt-4o-mini; the
    /// word "JSON" the mode requires is present in the card system prompt).
    enum ResponseFormat: Encodable {
        case jsonObject

        private enum CodingKeys: String, CodingKey { case type }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .jsonObject: try container.encode("json_object", forKey: .type)
            }
        }
    }

    private struct ChatRequest: Encodable {
        let model: String
        let temperature: Double
        let messages: [Message]
        let responseFormat: ResponseFormat?

        private enum CodingKeys: String, CodingKey {
            case model, temperature, messages
            case responseFormat = "response_format"
        }

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

/// Selection capability (TECH §03·2) — the structured-output prompt variant.
/// Word/phrase mode asks for a dictionary card in JSON mode and parses it via
/// the `parseCard` ladder; long-span mode reuses the free-text transport. Both
/// ride the same key, retries, and `choices[0].message.content` parsing as
/// translate/summarize.
extension OpenAIEngine: SelectionSpanTranslating {
    func translateSpan(span: String, context: String,
                       pair: LanguagePair, mode: SelectionMode) async throws -> SelectionOutput {
        let normalized = SpanNormalizer.normalize(span)
        let user = Self.selectionUserMessage(span: normalized, context: context)

        switch mode {
        case .wordPhrase:
            let request = try makeChatRequest(
                system: Self.cardSystemPrompt(from: pair.from, to: pair.to),
                user: user,
                temperature: 0.2,
                responseFormat: .jsonObject
            )
            let content = try Self.parse(try await fetchWithRetry(request))
            if let card = Self.parseCard(content, span: normalized) {
                return .card(card)
            }
            // Prose despite JSON mode: the FR-4-shaped fallback — no second
            // round-trip, no double billing. Brace-like content that failed
            // both parse passes is never rendered as a translation.
            guard !content.contains("{"), !content.contains("}") else {
                throw TranslationError.unexpectedResponse(engine: .ai)
            }
            return .plain(content)

        case .longSpan:
            let request = try makeChatRequest(
                system: Self.spanSystemPrompt(from: pair.from, to: pair.to),
                user: user,
                temperature: 0.2
            )
            return .plain(try Self.parse(try await fetchWithRetry(request)))
        }
    }
}

/// Selection prompt builders + the card parse ladder (TECH §03·2).
extension OpenAIEngine {

    /// System prompt for `SelectionMode.wordPhrase` — a bilingual dictionary
    /// answering with exactly ONE JSON object. Parameterized from the catalog's
    /// `aiName` exactly like `systemPrompt(from:to:)`; with Auto (`from == nil`)
    /// the lead switches to detecting the PASSAGE's language.
    static func cardSystemPrompt(from: Language?, to: Language) -> String {
        let target = to.aiName ?? to.englishName
        let lead: String
        if let from {
            let source = from.aiName ?? from.englishName
            lead = "You are a precise bilingual dictionary. The user message contains "
                + "a PASSAGE and a SPAN copied from it. Explain the SPAN exactly as it "
                + "is used in the PASSAGE, translating from \(source) into natural, "
                + "idiomatic \(target)."
        } else {
            lead = "You are a precise bilingual dictionary. The user message contains "
                + "a PASSAGE and a SPAN copied from it. Detect the PASSAGE's language "
                + "and explain the SPAN exactly as it is used in the PASSAGE, "
                + "translating it into natural, idiomatic \(target)."
        }
        return lead + """


        Respond with exactly ONE JSON object — no markdown fences, no commentary — using these keys:
          "translation"        (required) the \(target) translation of the SPAN as used in the PASSAGE
          "partOfSpeech"       (optional) short lowercase English tag for the SPAN's role in the PASSAGE, e.g. "verb", "noun phrase", "idiom"
          "sense"              (optional) one short \(target) line: what the SPAN means in this PASSAGE
          "example"            (optional) one NEW sentence in the PASSAGE's language using the SPAN in the same sense
          "exampleTranslation" (optional, only alongside "example") its \(target) translation

        Omit every optional key you cannot fill with confidence. Never invent, guess, or pad a field. Output ONLY the JSON object.
        """
    }

    /// System prompt for `SelectionMode.longSpan` — translate ONLY the SPAN,
    /// free text, no JSON anywhere. Same `aiName` parameterization and Auto
    /// handling as the card prompt.
    static func spanSystemPrompt(from: Language?, to: Language) -> String {
        let target = to.aiName ?? to.englishName
        let lead: String
        if let from {
            let source = from.aiName ?? from.englishName
            lead = "You are a precise translator. The user message contains a PASSAGE "
                + "and a SPAN copied from it. Translate ONLY the SPAN from \(source) "
                + "into natural, idiomatic \(target), using the PASSAGE solely to "
                + "resolve meaning, tone and references."
        } else {
            lead = "You are a precise translator. The user message contains a PASSAGE "
                + "and a SPAN copied from it. Detect the PASSAGE's language and "
                + "translate ONLY the SPAN into natural, idiomatic \(target), using "
                + "the PASSAGE solely to resolve meaning, tone and references."
        }
        return lead + " Preserve technical terms. Do not add quotes or commentary. "
            + "Output ONLY the translation of the SPAN, nothing else."
    }

    /// User message for both selection modes — the exact PASSAGE/SPAN layout
    /// the prompts describe. The span is normalized here so the wire message,
    /// the card headword, and the ⌘S save all agree on one spelling.
    static func selectionUserMessage(span: String, context: String) -> String {
        "PASSAGE:\n\(context)\n\nSPAN: \(SpanNormalizer.normalize(span))"
    }

    /// The pure parse ladder for card-mode content: strict `JSONDecoder` →
    /// lenient (slice first `{` … last `}`, which also sheds ``` fences and
    /// prose) → nil. Hygiene on both passes: fields trimmed, empty → nil,
    /// missing/empty `translation` fails the parse, `exampleTranslation`
    /// without `example` is dropped, and `headword` is ALWAYS the caller's
    /// normalized span — a model-echoed headword is ignored.
    static func parseCard(_ content: String, span: String) -> DictionaryCard? {
        let decoder = JSONDecoder()
        var payload = try? decoder.decode(CardPayload.self, from: Data(content.utf8))
        if payload == nil,
           let first = content.firstIndex(of: "{"),
           let last = content.lastIndex(of: "}"),
           first < last {
            payload = try? decoder.decode(
                CardPayload.self, from: Data(content[first...last].utf8)
            )
        }
        guard let payload, let translation = Self.cleaned(payload.translation) else {
            return nil
        }

        let example = Self.cleaned(payload.example)
        return DictionaryCard(
            headword: SpanNormalizer.normalize(span),
            translation: translation,
            partOfSpeech: Self.cleaned(payload.partOfSpeech),
            sense: Self.cleaned(payload.sense),
            example: example,
            exampleTranslation: example == nil ? nil : Self.cleaned(payload.exampleTranslation)
        )
    }

    /// Trims a decoded card field; empty means the model had nothing → nil.
    private static func cleaned(_ field: String?) -> String? {
        guard let trimmed = field?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Decode target for the card JSON — all-optional so hygiene (not the
    /// decoder) decides what survives; camelCase keys match the prompt.
    private struct CardPayload: Decodable {
        let translation: String?
        let partOfSpeech: String?
        let sense: String?
        let example: String?
        let exampleTranslation: String?
    }
}
