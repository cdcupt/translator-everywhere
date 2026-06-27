import Foundation
import Testing
@testable import Translator_Everywhere

/// Summarize behavior: the free engine formats a list with no network; the AI
/// engine sends a study-list prompt and returns the model's output (mocked).
@MainActor
@Suite("Summarize — free formats locally, AI uses the model", .serialized)
struct SummarizeTests {

    private func makeItems() throws -> [VocabItem] {
        let store = try NotebookStore(inMemory: true)
        let a = try store.add(source: "train platform", translation: "月台", from: "en", to: "zh-CN", engine: .free)
        let b = try store.add(source: "exit", translation: "出口", from: "en", to: "zh-CN", engine: .free)
        return [a, b]
    }

    @Test("Free engine returns a formatted list, no network")
    func freeFormatsList() async throws {
        // The mock session has no handler, so any network call throws
        // `.unsupportedURL`. The free engine must summarize without one — if it
        // tried, `summarize` would throw instead of returning the list.
        MockURLProtocol.reset()
        let engine = GoogleEngine(session: MockURLProtocol.makeSession(), retryDelay: .zero)
        let items = try makeItems()

        let summary = try await engine.summarize(items)

        #expect(summary.contains("Vocabulary list"))
        #expect(summary.contains("train platform — 月台"))
        #expect(summary.contains("exit — 出口"))
    }

    @Test("OpenAI engine sends a study-list prompt and returns the model summary")
    func aiSummary() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let mockedSummary = "## Transit\n- train platform: The train platform was crowded."
        MockURLProtocol.handler = { request in
            let json: [String: Any] = [
                "choices": [["message": ["role": "assistant", "content": mockedSummary]]],
            ]
            let data = try! JSONSerialization.data(withJSONObject: json)
            return (data, MockURLProtocol.okResponse(for: request))
        }

        let engine = OpenAIEngine(
            apiKey: "sk-test",
            session: MockURLProtocol.makeSession(),
            retryDelay: .zero
        )
        let items = try makeItems()

        let summary = try await engine.summarize(items)
        #expect(summary == mockedSummary)

        // It went to the chat-completions endpoint.
        let sent = try #require(MockURLProtocol.lastRequest)
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/chat/completions")

        // The summarize request must carry the study-list system prompt + the
        // numbered items. (Inspect the built request directly: URLSession streams
        // the body, so `lastRequest.httpBody` is nil.)
        let request = try engine.makeChatRequest(
            system: OpenAIEngine.summarizeSystemPrompt,
            user: StudyListFormatter.promptLines(items),
            temperature: 0.4
        )
        let body = try #require(request.httpBody)
        let raw = String(decoding: body, as: UTF8.self)
        #expect(raw.contains("study coach"))
        #expect(raw.contains("train platform"))
    }

    @Test("OpenAI summarize on empty items throws emptyInput")
    func aiSummaryEmpty() async {
        let engine = OpenAIEngine(apiKey: "sk-test", retryDelay: .zero)
        await #expect(throws: TranslationError.self) {
            _ = try await engine.summarize([])
        }
    }
}
