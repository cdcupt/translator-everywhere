import Foundation
import Testing
@testable import Translator_Everywhere

@Suite("OpenAIEngine — payload, prompt, parsing, errors")
struct OpenAIEngineTests {

    private let chinese = LanguageCatalog.language(forCode: "zh-CN")!
    private let english = LanguageCatalog.language(forCode: "en")!

    private func autoRequest(_ text: String) -> TranslationRequest {
        TranslationRequest(text: text, from: nil, to: chinese)
    }

    private func chatResponse(content: String) -> Data {
        let json: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": content]]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test("Builds the chat-completions payload and returns an AI result")
    func buildsPayload() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { request in
            (self.chatResponse(content: "你好"), MockURLProtocol.okResponse(for: request))
        }

        let engine = OpenAIEngine(
            apiKey: "sk-test-123",
            session: MockURLProtocol.makeSession(),
            retryDelay: .zero
        )
        let result = try await engine.translate(autoRequest("Hello"))

        #expect(result.translation == "你好")
        #expect(result.servedBy == .ai)
        #expect(result.viaGoogleFallback == false)
        // Auto: the AI path's real detection is slice 6 — unavailable for now.
        #expect(result.detected == .unavailable)
        #expect(engine.kind == .ai)

        let sent = try #require(MockURLProtocol.lastRequest)
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-123")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("Auto prompt carries the target aiName and asks the model to detect the source")
    func autoPromptCarriesTarget() throws {
        let engine = OpenAIEngine(apiKey: "sk-x")
        let request = try engine.makeRequest(for: autoRequest("Hello"), text: "Hello")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["model"] as? String == "gpt-4o-mini")
        #expect((json["temperature"] as? Double) == 0.2)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        let system = try #require(messages[0]["content"] as? String)
        #expect(messages[0]["role"] as? String == "system")
        #expect(system.contains("Simplified Chinese"))    // target aiName
        #expect(system.contains("Detect"))                // Auto → detect the source
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "Hello")
    }

    @Test("Explicit From names both languages in the prompt")
    func explicitFromNamesBothLanguages() throws {
        let engine = OpenAIEngine(apiKey: "sk-x")
        let request = TranslationRequest(text: "你好", from: chinese, to: english)
        let urlRequest = try engine.makeRequest(for: request, text: "你好")
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let system = try #require(messages[0]["content"] as? String)

        #expect(system.contains("Simplified Chinese")) // source aiName
        #expect(system.contains("English"))            // target aiName
        #expect(!system.contains("Detect"))            // explicit From bypasses detection
    }

    @Test("Explicit From echoes the source in the result's detected metadata")
    func explicitFromEchoesDetected() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { request in
            (self.chatResponse(content: "Hello"), MockURLProtocol.okResponse(for: request))
        }
        let engine = OpenAIEngine(
            apiKey: "sk-x", session: MockURLProtocol.makeSession(), retryDelay: .zero
        )
        let request = TranslationRequest(text: "你好", from: chinese, to: english)
        let result = try await engine.translate(request)

        #expect(result.detected == .identified(chinese, confidence: nil))
    }

    @Test("Parses choices[0].message.content")
    func parsesContent() throws {
        let data = chatResponse(content: "  translated  ")
        let result = try OpenAIEngine.parse(data)
        #expect(result == "translated")
    }

    // MARK: - Contextual selection (TECH §03·2 / §04 U-17..U-27)

    /// U-17 — card prompt names both aiNames, lists all five JSON keys, and
    /// demands exactly ONE JSON object.
    @Test("U-17: card system prompt — explicit pair, five keys, one JSON object")
    func cardSystemPromptExplicitPair() {
        let prompt = OpenAIEngine.cardSystemPrompt(from: english, to: chinese)

        // Both aiNames, pinned in the translating clause (not the key block,
        // whose "lowercase English tag" wording would satisfy a bare contains).
        #expect(prompt.contains("from English into natural, idiomatic Simplified Chinese"))
        #expect(prompt.contains("exactly ONE JSON object"))
        for key in ["\"translation\"", "\"partOfSpeech\"", "\"sense\"",
                    "\"example\"", "\"exampleTranslation\""] {
            #expect(prompt.contains(key), "missing JSON key \(key)")
        }
        #expect(!prompt.contains("Detect")) // explicit From bypasses detection
    }

    /// U-18 — with Auto (`from == nil`) the lead switches to detection.
    @Test("U-18: card system prompt — Auto switches to Detect the PASSAGE's language")
    func cardSystemPromptAutoDetects() {
        let prompt = OpenAIEngine.cardSystemPrompt(from: nil, to: chinese)

        #expect(prompt.contains("Detect the PASSAGE's language"))
        #expect(prompt.contains("into natural, idiomatic Simplified Chinese")) // target still named
        #expect(!prompt.contains("from English into")) // no source to name
    }

    /// U-19 — long-span prompt: translate-ONLY-the-SPAN, no JSON keys anywhere.
    @Test("U-19: span system prompt — translate ONLY the SPAN, no JSON")
    func spanSystemPromptLongSpan() {
        let prompt = OpenAIEngine.spanSystemPrompt(from: english, to: chinese)

        #expect(prompt.contains("Translate ONLY the SPAN"))
        #expect(prompt.contains("English"))            // source aiName
        #expect(prompt.contains("Simplified Chinese")) // target aiName
        #expect(!prompt.contains("JSON"))
        for key in ["\"translation\"", "\"partOfSpeech\"", "\"sense\"",
                    "\"example\"", "\"exampleTranslation\""] {
            #expect(!prompt.contains(key), "long-span prompt must not carry \(key)")
        }
    }

    /// U-20 — exact PASSAGE/SPAN layout; span pre-normalized.
    @Test("U-20: selection user message — exact layout, normalized span")
    func selectionUserMessageLayout() {
        let message = OpenAIEngine.selectionUserMessage(
            span: "  scored \n ",
            context: "Messi scored the final goal."
        )

        #expect(message == "PASSAGE:\nMessi scored the final goal.\n\nSPAN: scored")
    }

    /// U-21 — wire body: card mode carries response_format json_object, model
    /// gpt-4o-mini, temp 0.2; long-span carries NO response_format; both use
    /// the PASSAGE/SPAN user message.
    @Test("U-21: wire body — card vs long-span request shape")
    func wireBodyCardVsLongSpan() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let card = ["translation": "攻入"]
        let cardContent = String(data: try JSONSerialization.data(withJSONObject: card), encoding: .utf8)!
        MockURLProtocol.handler = { request in
            (self.chatResponse(content: cardContent), MockURLProtocol.okResponse(for: request))
        }
        let engine = OpenAIEngine(
            apiKey: "sk-test-123",
            session: MockURLProtocol.makeSession(),
            retryDelay: .zero
        )
        let pair = LanguagePair(from: english, to: chinese)

        // Card mode.
        _ = try await engine.translateSpan(
            span: "scored", context: "Messi scored the final goal.",
            pair: pair, mode: .wordPhrase
        )
        let cardBody = try #require(MockURLProtocol.lastBody)
        let cardJSON = try #require(try JSONSerialization.jsonObject(with: cardBody) as? [String: Any])

        #expect(Set(cardJSON.keys) == ["model", "temperature", "messages", "response_format"])
        #expect(cardJSON["model"] as? String == "gpt-4o-mini")
        #expect(cardJSON["temperature"] as? Double == 0.2)
        let responseFormat = try #require(cardJSON["response_format"] as? [String: Any])
        #expect(responseFormat as? [String: String] == ["type": "json_object"])
        let cardMessages = try #require(cardJSON["messages"] as? [[String: Any]])
        #expect(cardMessages.count == 2)
        #expect(cardMessages[0]["role"] as? String == "system")
        #expect(cardMessages[0]["content"] as? String
            == OpenAIEngine.cardSystemPrompt(from: english, to: chinese))
        #expect(cardMessages[1]["role"] as? String == "user")
        #expect(cardMessages[1]["content"] as? String
            == "PASSAGE:\nMessi scored the final goal.\n\nSPAN: scored")

        // Long-span mode.
        MockURLProtocol.handler = { request in
            (self.chatResponse(content: "梅西攻入了最后一球"), MockURLProtocol.okResponse(for: request))
        }
        _ = try await engine.translateSpan(
            span: "Messi scored the final goal.", context: "Messi scored the final goal.",
            pair: pair, mode: .longSpan
        )
        let spanBody = try #require(MockURLProtocol.lastBody)
        let spanJSON = try #require(try JSONSerialization.jsonObject(with: spanBody) as? [String: Any])

        #expect(Set(spanJSON.keys) == ["model", "temperature", "messages"]) // no response_format
        #expect(spanJSON["model"] as? String == "gpt-4o-mini")
        #expect(spanJSON["temperature"] as? Double == 0.2)
        let spanMessages = try #require(spanJSON["messages"] as? [[String: Any]])
        #expect(spanMessages[0]["content"] as? String
            == OpenAIEngine.spanSystemPrompt(from: english, to: chinese))
        #expect(spanMessages[1]["content"] as? String
            == "PASSAGE:\nMessi scored the final goal.\n\nSPAN: Messi scored the final goal.")
    }

    /// U-22 — strict JSON decodes; a model-echoed headword is ignored in favor
    /// of the caller's normalized span.
    @Test("U-22: parseCard strict — full card, headword forced to the span")
    func parseCardStrictIgnoresEchoedHeadword() {
        let content = """
        {"headword": "goal", "translation": "攻入", "partOfSpeech": "verb", \
        "sense": "射门得分", "example": "He scored twice last night.", \
        "exampleTranslation": "他昨晚梅开二度。"}
        """

        let card = OpenAIEngine.parseCard(content, span: "scored")

        #expect(card == DictionaryCard(
            headword: "scored", // echo "goal" ignored
            translation: "攻入",
            partOfSpeech: "verb",
            sense: "射门得分",
            example: "He scored twice last night.",
            exampleTranslation: "他昨晚梅开二度。"
        ))
    }

    /// U-23 — lenient pass: strip fences, slice first { … last }.
    @Test("U-23: parseCard lenient — fenced JSON with surrounding prose decodes")
    func parseCardLenientFences() {
        let content = """
        Sure! Here is the card:
        ```json
        {"translation": "攻入", "partOfSpeech": "verb"}
        ```
        Hope this helps!
        """

        let card = OpenAIEngine.parseCard(content, span: "scored")

        #expect(card?.translation == "攻入")
        #expect(card?.partOfSpeech == "verb")
        #expect(card?.headword == "scored")
    }

    /// U-24 — hygiene: empty fields → nil; exampleTranslation without example
    /// is dropped, never faked.
    @Test("U-24: parseCard hygiene — empties to nil, orphaned exampleTranslation dropped")
    func parseCardHygiene() {
        let content = """
        {"translation": " 攻入 ", "partOfSpeech": "", "sense": "  ", \
        "exampleTranslation": "orphaned"}
        """

        let card = OpenAIEngine.parseCard(content, span: "scored")

        #expect(card == DictionaryCard(
            headword: "scored",
            translation: "攻入",      // trimmed
            partOfSpeech: nil,        // empty → nil (row omitted)
            sense: nil,               // whitespace-only → nil
            example: nil,
            exampleTranslation: nil   // orphaned — dropped
        ))
    }

    /// U-25 — missing or empty `translation` fails the whole parse.
    @Test("U-25: parseCard — missing or empty translation returns nil")
    func parseCardRequiresTranslation() {
        #expect(OpenAIEngine.parseCard("{\"partOfSpeech\": \"verb\"}", span: "scored") == nil)
        #expect(OpenAIEngine.parseCard("{\"translation\": \"\"}", span: "scored") == nil)
        #expect(OpenAIEngine.parseCard("{\"translation\": \"  \"}", span: "scored") == nil)
    }

    /// U-26 — card mode, prose answer with no braces: `.plain(content)` —
    /// FR-4-shaped fallback, no throw, no second request.
    @Test("U-26: translateSpan card mode — prose degrades to .plain, one request")
    func translateSpanProseDegradesToPlain() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return (
                self.chatResponse(content: "It means to put the ball in the net."),
                MockURLProtocol.okResponse(for: request)
            )
        }
        let engine = OpenAIEngine(
            apiKey: "sk-x", session: MockURLProtocol.makeSession(), retryDelay: .zero
        )

        let output = try await engine.translateSpan(
            span: "scored", context: "Messi scored the final goal.",
            pair: LanguagePair(from: english, to: chinese), mode: .wordPhrase
        )

        #expect(output == .plain("It means to put the ball in the net."))
        #expect(requestCount == 1) // no second round-trip, no double billing
    }

    /// U-27 — brace-like content failing both parse passes throws
    /// `.unexpectedResponse(.ai)` — never renders half-parsed JSON.
    @Test("U-27: translateSpan card mode — undecodable braces throw unexpectedResponse")
    func translateSpanBrokenJSONThrows() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { request in
            (
                self.chatResponse(content: "{\"translation\": broken"),
                MockURLProtocol.okResponse(for: request)
            )
        }
        let engine = OpenAIEngine(
            apiKey: "sk-x", session: MockURLProtocol.makeSession(), retryDelay: .zero
        )

        do {
            _ = try await engine.translateSpan(
                span: "scored", context: "Messi scored the final goal.",
                pair: LanguagePair(from: english, to: chinese), mode: .wordPhrase
            )
            Issue.record("expected unexpectedResponse(.ai)")
        } catch let error as TranslationError {
            guard case .unexpectedResponse(let engineKind) = error else {
                Issue.record("unexpected TranslationError: \(error)")
                return
            }
            #expect(engineKind == .ai)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Surfaces the API error message")
    func surfacesAPIError() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let errorBody = try! JSONSerialization.data(withJSONObject: [
            "error": ["message": "Incorrect API key provided"],
        ])
        MockURLProtocol.handler = { request in
            (errorBody, MockURLProtocol.okResponse(for: request))
        }

        let engine = OpenAIEngine(
            apiKey: "bad",
            session: MockURLProtocol.makeSession(),
            retryDelay: .zero
        )

        do {
            _ = try await engine.translate(autoRequest("Hello"))
            Issue.record("expected an error")
        } catch let error as TranslationError {
            #expect(error.errorDescription == "Incorrect API key provided")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
