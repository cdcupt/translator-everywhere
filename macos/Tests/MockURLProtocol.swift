import Foundation

/// A `URLProtocol` that intercepts every request so tests can stub the network
/// without hitting Google / OpenAI. Install it via a custom `URLSession`
/// configuration and set `handler` to return canned `(Data, HTTPURLResponse)`
/// or throw to simulate a transport failure.
final class MockURLProtocol: URLProtocol {

    /// Per-test request handler. Receives the outgoing request; returns the
    /// canned response, or throws to simulate a network error.
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    /// Captures the last request seen, for payload/URL assertions.
    nonisolated(unsafe) static var lastRequest: URLRequest?

    /// Captures the last request *body*. `URLProtocol` strips `httpBody` for
    /// streamed uploads, so we drain `httpBodyStream` here — the only reliable
    /// way to assert push / sign-in body shapes in tests.
    nonisolated(unsafe) static var lastBody: Data?

    static func reset() {
        handler = nil
        lastRequest = nil
        lastBody = nil
    }

    /// Builds a `URLSession` wired to this protocol.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.lastRequest = request
        MockURLProtocol.lastBody = Self.bodyData(from: request)

        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// Reads the outgoing body, preferring the inline `httpBody` and falling back
    /// to draining `httpBodyStream` (what `URLSession` actually sends).
    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Helpers for building canned responses in tests.
extension MockURLProtocol {
    static func okResponse(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
