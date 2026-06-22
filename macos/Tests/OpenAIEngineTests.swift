import Foundation
import Testing
@testable import Translator_Everywhere

@Suite("OpenAIEngine — payload, parsing, errors")
struct OpenAIEngineTests {

    private func chatResponse(content: String) -> Data {
        let json: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": content]]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test("Builds the chat-completions payload with model, prompt, and auth header")
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
        let result = try await engine.translate("Hello")

        #expect(result == "你好")
        #expect(engine.kind == .ai)

        let sent = try #require(MockURLProtocol.lastRequest)
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-123")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("Request body carries default model, temperature, and system+user messages")
    func requestBodyShape() throws {
        let engine = OpenAIEngine(apiKey: "sk-x")
        let request = try engine.makeRequest(text: "Hello")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["model"] as? String == "gpt-4o-mini")
        #expect((json["temperature"] as? Double) == 0.2)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect((messages[0]["content"] as? String)?.contains("precise translator") == true)
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "Hello")
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
            _ = try await engine.translate("Hello")
            Issue.record("expected an error")
        } catch let error as TranslationError {
            #expect(error.errorDescription == "Incorrect API key provided")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
