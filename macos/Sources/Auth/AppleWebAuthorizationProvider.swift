import Foundation

/// Acquires a finished Apple sign-in callback by driving the system browser.
///
/// Unlike Google (which returns only a `code` the app then exchanges), the Apple
/// *web* flow lets the backend do the whole exchange: the app opens Apple's
/// `/auth/authorize`, Apple redirects to our backend's `redirect_uri`, the
/// backend verifies the `code`, mints our session, and 302s back to the app's
/// custom scheme carrying the finished tokens. So this provider returns the full
/// callback `URL` (`translator-everywhere://apple-callback?session=&refresh=&state=`)
/// and `AuthClient` parses it. The real driver opens the browser via
/// `WebAuthRouter`; tests inject a stub so the parse + store can run headlessly.
protocol AppleWebAuthorizationProvider: Sendable {
    /// Presents the consent UI for `authorizationURL` and returns the custom-scheme
    /// callback URL the backend redirected to (carrying `session`/`refresh`/`state`,
    /// or `error`/`state`). `callbackScheme` is the registered custom scheme.
    func callbackURL(authorizationURL: URL, callbackScheme: String) async throws -> URL
}

/// Real Apple web-authorization driver. Opens Apple's `/auth/authorize` in the
/// user's default browser and waits — via `WebAuthRouter` — for the backend's
/// hand-back redirect to `translator-everywhere://apple-callback?...`, returning
/// that final URL.
///
/// Like the Google provider, it avoids `ASWebAuthenticationSession`, which on
/// macOS hands the login to the default browser and is broken when that browser
/// is Chrome/Firefox. The parse + token storage after it is plain logic and is
/// fully unit-tested.
final class WebAppleAuthorizationProvider: AppleWebAuthorizationProvider {

    func callbackURL(authorizationURL: URL, callbackScheme: String) async throws -> URL {
        // The backend echoes the `state` we put on the authorize URL, so match the
        // hand-back redirect to this request by it.
        let state = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        return try await WebAuthRouter.shared.open(authorizationURL, awaitingState: state)
    }
}
