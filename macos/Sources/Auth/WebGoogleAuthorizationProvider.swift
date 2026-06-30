import AppKit
import Foundation

/// Real Google authorization driver — a **Desktop-app OAuth client with a loopback
/// redirect**. It binds `127.0.0.1` on an ephemeral port, opens the consent page in
/// the user's default browser, and captures the post-consent `?code`+`state` on
/// localhost, then validates `state`.
///
/// This replaced the earlier reverse-DNS custom-scheme redirect, which is an
/// *iOS*-client pattern: desktop Chrome silently drops a server-initiated redirect
/// to a `com.googleusercontent.apps.…` custom scheme (`ERR_UNKNOWN_URL_SCHEME`), so
/// the callback never returned and sign-in hung. Loopback is Google's documented
/// desktop pattern and works in any browser (the browser just navigates to
/// `http://127.0.0.1:<port>` — no scheme/LaunchServices handoff). Everything after
/// (token exchange, backend POST) is plain networking and is fully unit-tested.
final class WebGoogleAuthorizationProvider: GoogleAuthorizationProvider {

    func authorizationCode(
        expectedState: String,
        buildAuthorizationURL: (_ redirectURI: String) -> URL
    ) async throws -> (code: String, redirectURI: String) {
        let listener = try LoopbackRedirectListener()
        defer { listener.stop() }

        let redirectURI = listener.redirectURI
        guard NSWorkspace.shared.open(buildAuthorizationURL(redirectURI)) else {
            throw AuthError.providerResponseInvalid
        }
        let callbackURL = try await listener.waitForRedirect()
        let code = try Self.extractCode(from: callbackURL, expectedState: expectedState)
        return (code, redirectURI)
    }

    /// Pulls `code` from the redirect, rejecting an `error=` response or a
    /// mismatched `state` (CSRF guard).
    static func extractCode(from url: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AuthError.providerResponseInvalid
        }
        let items = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        if items["error"] != nil {
            throw AuthError.providerResponseInvalid
        }
        guard items["state"] == expectedState else {
            throw AuthError.providerResponseInvalid
        }
        guard let code = items["code"], !code.isEmpty else {
            throw AuthError.providerResponseInvalid
        }
        return code
    }
}
