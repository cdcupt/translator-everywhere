import Foundation
import Testing
@testable import Translator_Everywhere

@Suite("GoogleEngine — request, parsing, detected source")
struct GoogleEngineTests {

    private let chinese = LanguageCatalog.language(forCode: "zh-CN")!
    private let english = LanguageCatalog.language(forCode: "en")!
    private let hebrew = LanguageCatalog.language(forCode: "he")!

    /// A canned response body in Google's nested-array shape.
    /// `[[["译文","src",null,null,1]], null, "<detected>"]`. Pass `detected: nil`
    /// to omit the source (root[2] = null) → the engine reports `.uncertain`.
    private func cannedBody(segments: [String], detected: String? = "en") -> Data {
        let inner = segments.map { ["\($0)", "src", NSNull(), NSNull()] as [Any] }
        let root: [Any] = [inner, NSNull(), (detected as Any?) ?? NSNull()]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private func request(_ text: String) -> TranslationRequest {
        TranslationRequest(text: text, from: nil, to: chinese)
    }

    @Test("Parses a canned Google response into the joined translation + FREE result")
    func parsesCannedResponse() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let body = cannedBody(segments: ["Hello, ", "world."], detected: "en")
        MockURLProtocol.handler = { request in
            (body, MockURLProtocol.okResponse(for: request))
        }

        let engine = GoogleEngine(session: MockURLProtocol.makeSession(), retryDelay: .zero)
        let result = try await engine.translate(request("你好，世界。"))

        #expect(result.translation == "Hello, world.")
        #expect(result.servedBy == .free)
        #expect(result.viaGoogleFallback == false)
        #expect(result.detected == .identified(english, confidence: nil))
        #expect(engine.kind == .free)
    }

    @Test("Maps a divergent detected code (iw) back to its canonical Language (he)")
    func mapsDivergentDetectedCode() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let body = cannedBody(segments: ["hello"], detected: "iw") // Google sends iw for Hebrew
        MockURLProtocol.handler = { request in
            (body, MockURLProtocol.okResponse(for: request))
        }

        let engine = GoogleEngine(session: MockURLProtocol.makeSession(), retryDelay: .zero)
        let result = try await engine.translate(request("שלום"))

        #expect(result.detected == .identified(hebrew, confidence: nil))
        #expect(result.detected != .identified(english, confidence: nil))
    }

    @Test("No detected source in the response yields .uncertain (suppresses the guard)")
    func noDetectedSourceIsUncertain() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let body = cannedBody(segments: ["你好"], detected: nil) // root[2] = null, no root[8]
        MockURLProtocol.handler = { request in
            (body, MockURLProtocol.okResponse(for: request))
        }

        let engine = GoogleEngine(session: MockURLProtocol.makeSession(), retryDelay: .zero)
        let result = try await engine.translate(request("hi"))

        #expect(result.translation == "你好")
        #expect(result.detected == .uncertain)
    }

    @Test("Auto request sends sl=auto and the pair's tl")
    func autoRequestQueryParams() throws {
        let req = try GoogleEngine.makeRequest(text: "hi", sourceCode: "auto", targetCode: "zh-CN")
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value) })

        #expect(comps.host == "translate.googleapis.com")
        #expect(items["client"] == "gtx")
        #expect(items["sl"] == "auto")
        #expect(items["tl"] == "zh-CN")
        #expect(items["dt"] == "t")
        #expect(items["q"] == "hi")
    }

    @Test("Explicit From drives sl from the source language's Google code")
    func explicitFromDrivesSourceCode() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { request in
            (self.cannedBody(segments: ["שלום"], detected: "iw"), MockURLProtocol.okResponse(for: request))
        }
        let engine = GoogleEngine(session: MockURLProtocol.makeSession(), retryDelay: .zero)
        // from: Hebrew (code he → googleCode iw), to: English.
        _ = try await engine.translate(TranslationRequest(text: "hello", from: hebrew, to: english))

        let sent = try #require(MockURLProtocol.lastRequest)
        let comps = URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value) })
        #expect(items["sl"] == "iw")
        #expect(items["tl"] == "en")
    }

    @Test("Empty input throws emptyInput")
    func emptyInputThrows() async {
        let engine = GoogleEngine(session: MockURLProtocol.makeSession(), retryDelay: .zero)
        await #expect(throws: TranslationError.self) {
            _ = try await engine.translate(request("   "))
        }
    }

    @Test("Unparseable response surfaces unexpectedResponse")
    func unparseableResponse() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { request in
            (Data("not json".utf8), MockURLProtocol.okResponse(for: request))
        }
        let engine = GoogleEngine(session: MockURLProtocol.makeSession(), retryDelay: .zero)
        await #expect(throws: TranslationError.self) {
            _ = try await engine.translate(request("hello"))
        }
    }
}
