import Foundation

/// Real Google authorization driver. Opens the consent URL in the user's default
/// browser and waits — via `WebAuthRouter` — for the post-consent redirect back
/// to the app's registered `com.googleusercontent.apps.…` scheme, then pulls out
/// the `code` (validating `state`).
///
/// This deliberately does NOT use `ASWebAuthenticationSession`: on macOS that API
/// routes the login to the *default browser* and is broken when that browser is
/// Chrome/Firefox (the auth window opens then immediately closes, so no page is
/// shown). Driving the browser ourselves + capturing the custom-scheme redirect
/// works with any default browser. Everything after (token exchange, backend
/// POST) is plain networking and is fully unit-tested.
final class WebGoogleAuthorizationProvider: GoogleAuthorizationProvider {

    func authorizationCode(
        authorizationURL: URL,
        redirectScheme: String,
        expectedState: String
    ) async throws -> String {
        let callbackURL = try await WebAuthRouter.shared.open(
            authorizationURL,
            awaitingState: expectedState
        )
        return try Self.extractCode(from: callbackURL, expectedState: expectedState)
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
