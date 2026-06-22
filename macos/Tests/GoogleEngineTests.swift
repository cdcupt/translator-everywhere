import Foundation
import Testing
@testable import Translator_Everywhere

@Suite("GoogleEngine — direction, parsing, request")
struct GoogleEngineTests {

    /// A canned response body in Google's nested-array shape.
    /// `[[["译文","src",null,null,1]], null, "en"]`
    private func cannedBody(segments: [String]) -> Data {
        let inner = segments.map { ["\($0)", "src", NSNull(), NSNull()] as [Any] }
        let root: [Any] = [inner, NSNull(), "en"]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    @Test("Parses a canned Google response into the joined translation")
    func parsesCannedResponse() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let body = cannedBody(segments: ["Hello, ", "world."])
        MockURLProtocol.handler = { request in
            (body, MockURLProtocol.okResponse(for: request))
        }

        let engine = GoogleEngine(session: MockURLProtocol.makeSession(), retryDelay: .zero)
        let result = try await engine.translate("你好，世界。")

        #expect(result == "Hello, world.")
        #expect(engine.kind == .free)
    }

    @Test("Chinese input targets English (tl=en)")
    func chineseInputTargetsEnglish() {
        let target = LanguageDirection.target(for: "你好世界")
        #expect(target.googleCode == "en")
    }

    @Test("English input targets Simplified Chinese (tl=zh-CN)")
    func englishInputTargetsChinese() {
        let target = LanguageDirection.target(for: "Hello world")
        #expect(target.googleCode == "zh-CN")
    }

    @Test("Request carries the te-compatible query params")
    func requestQueryParams() throws {
        let request = try GoogleEngine.makeRequest(text: "hi", target: .simplifiedChinese)
        let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value) })

        #expect(comps.host == "translate.googleapis.com")
        #expect(items["client"] == "gtx")
        #expect(items["sl"] == "auto")
        #expect(items["tl"] == "zh-CN")
        #expect(items["dt"] == "t")
        #expect(items["q"] == "hi")
    }

    @Test("Empty input throws emptyInput")
    func emptyInputThrows() async {
        let engine = GoogleEngine(session: MockURLProtocol.makeSession(), retryDelay: .zero)
        await #expect(throws: TranslationError.self) {
            _ = try await engine.translate("   ")
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
            _ = try await engine.translate("hello")
        }
    }
}
