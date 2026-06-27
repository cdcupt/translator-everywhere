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
