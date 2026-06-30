import Foundation

/// A one-shot localhost HTTP listener for an OAuth **loopback** redirect.
///
/// Binds `127.0.0.1` on an ephemeral port, serves exactly one `GET` (the browser's
/// post-consent redirect carrying `code`+`state`), replies with a tiny
/// "you can close this" page, and returns the redirect URL. Loopback is Google's
/// documented redirect for **Desktop** OAuth clients and works in any default
/// browser — unlike a custom URL scheme, which desktop Chrome silently drops
/// (`ERR_UNKNOWN_URL_SCHEME`) when it follows a server-initiated redirect.
///
/// Binds to `127.0.0.1` (not `0.0.0.0`) so the macOS application firewall never
/// prompts and no inbound-network entitlement is needed (the app's sandbox is off;
/// Hardened Runtime doesn't block socket binding).
final class LoopbackRedirectListener {

    enum ListenerError: Error { case socketSetupFailed }

    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false

    /// The bound ephemeral port.
    let port: UInt16

    /// The `redirect_uri` the browser is sent to. It MUST be passed unchanged to
    /// both the authorize URL and the token exchange (Google requires them equal).
    var redirectURI: String { "http://127.0.0.1:\(port)/oauth2redirect" }

    init() throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw ListenerError.socketSetupFailed }

        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                              // ephemeral — kernel assigns
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // loopback only

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(s, 1) == 0 else { close(s); throw ListenerError.socketSetupFailed }

        var name = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        guard named == 0 else { close(s); throw ListenerError.socketSetupFailed }

        self.fd = s
        self.port = UInt16(bigEndian: name.sin_port)
    }

    /// Accepts one connection, reads the request line, replies with a small page,
    /// and returns the full redirect URL. Cancellation closes the socket, which
    /// unblocks the pending `accept` so a watchdog timeout can win cleanly.
    func waitForRedirect() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                DispatchQueue.global().async { [fd, port] in
                    let conn = accept(fd, nil, nil)
                    guard conn >= 0 else {
                        // accept failed — almost always because the socket was
                        // closed on cancellation. Surface as cancelled.
                        cont.resume(throwing: AuthError.cancelled)
                        return
                    }
                    defer { close(conn) }

                    var buf = [UInt8](repeating: 0, count: 8192)
                    let n = read(conn, &buf, buf.count)
                    let request = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
                    let firstLine = request.split(
                        separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false
                    ).first.map(String.init) ?? ""

                    let body = """
                    <!doctype html><html><head><meta charset="utf-8">\
                    <title>Translator Everywhere</title></head>\
                    <body style="font-family:-apple-system,system-ui,sans-serif;text-align:center;padding-top:4rem;color:#222">\
                    <h2>You're signed in.</h2><p>You can close this window and return to Translator Everywhere.</p>\
                    </body></html>
                    """
                    let response = "HTTP/1.1 200 OK\r\n"
                        + "Content-Type: text/html; charset=utf-8\r\n"
                        + "Content-Length: \(body.utf8.count)\r\n"
                        + "Connection: close\r\n\r\n"
                        + body
                    Data(response.utf8).withUnsafeBytes { raw in
                        _ = write(conn, raw.baseAddress, raw.count)
                    }

                    guard let target = Self.requestTarget(from: firstLine),
                          let url = URL(string: "http://127.0.0.1:\(port)\(target)") else {
                        cont.resume(throwing: AuthError.providerResponseInvalid)
                        return
                    }
                    cont.resume(returning: url)
                }
            }
        } onCancel: {
            stop()
        }
    }

    /// Closes the listening socket (idempotent; also unblocks a pending `accept`).
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if !isClosed { close(fd); isClosed = true }
    }

    /// Pure parser: pulls the request target out of an HTTP request line such as
    /// `GET /oauth2redirect?code=…&state=… HTTP/1.1`. Returns `nil` for anything
    /// that isn't a `GET` of an absolute path. Unit-testable without a socket.
    static func requestTarget(from requestLine: String) -> String? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let target = String(parts[1])
        return target.hasPrefix("/") ? target : nil
    }
}
