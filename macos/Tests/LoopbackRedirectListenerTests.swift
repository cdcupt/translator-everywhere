import Foundation
import Testing
@testable import Translator_Everywhere

/// The localhost loopback listener that captures Google's Desktop-OAuth redirect.
@Suite("LoopbackRedirectListener — request-line parsing + real loopback round-trip")
struct LoopbackRedirectListenerTests {

    // MARK: - Pure parser

    @Test("requestTarget extracts the path+query from a GET request line")
    func parsesGetTarget() {
        #expect(LoopbackRedirectListener.requestTarget(
            from: "GET /oauth2redirect?code=abc&state=xyz HTTP/1.1") == "/oauth2redirect?code=abc&state=xyz")
        #expect(LoopbackRedirectListener.requestTarget(from: "GET / HTTP/1.1") == "/")
    }

    @Test("requestTarget rejects non-GET or malformed lines")
    func rejectsBadRequestLines() {
        #expect(LoopbackRedirectListener.requestTarget(from: "POST /oauth2redirect HTTP/1.1") == nil)
        #expect(LoopbackRedirectListener.requestTarget(from: "GET oauth2redirect HTTP/1.1") == nil) // no leading /
        #expect(LoopbackRedirectListener.requestTarget(from: "") == nil)
        #expect(LoopbackRedirectListener.requestTarget(from: "GET") == nil)
    }

    // MARK: - Real loopback round-trip

    @Test("binds 127.0.0.1, captures a GET, and returns the redirect URL with code+state")
    func capturesLoopbackRedirect() async throws {
        let listener = try LoopbackRedirectListener()
        defer { listener.stop() }
        #expect(listener.redirectURI == "http://127.0.0.1:\(listener.port)/oauth2redirect")

        // Start awaiting the redirect, then connect a client. The TCP listen
        // backlog queues the connection until accept() runs — no sleep needed.
        let waiting = Task { try await listener.waitForRedirect() }
        Self.sendGet(to: listener.port, path: "/oauth2redirect?code=abc-123&state=st-xyz")

        let url = try await waiting.value
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first(where: { $0.name == "code" })?.value == "abc-123")
        #expect(items.first(where: { $0.name == "state" })?.value == "st-xyz")
    }

    /// Opens a blocking client socket to 127.0.0.1:port, sends a minimal GET, reads
    /// the response, and closes. Runs on a background thread so it doesn't block the
    /// awaiting test task.
    private static func sendGet(to port: UInt16, path: String) {
        DispatchQueue.global().async {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { return }
            defer { close(s) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard ok == 0 else { return }
            let req = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
            _ = req.withCString { write(s, $0, strlen($0)) }
            var buf = [UInt8](repeating: 0, count: 1024)
            _ = read(s, &buf, buf.count) // drain the server's response so it can close
        }
    }
}
