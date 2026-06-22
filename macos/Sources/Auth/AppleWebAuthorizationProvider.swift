import AuthenticationServices
import Foundation

/// Acquires a finished Apple sign-in callback by driving the system browser.
///
/// Unlike Google (which returns only a `code` the app then exchanges), the Apple
/// *web* flow lets the backend do the whole exchange: the app opens Apple's
/// `/auth/authorize`, Apple redirects to our backend's `redirect_uri`, the
/// backend verifies the `code`, mints our session, and 302s back to the app's
/// custom scheme carrying the finished tokens. So this provider returns the full
/// callback `URL` (`translator-everywhere://apple-callback?session=&refresh=&state=`)
/// and `AuthClient` parses it. The real driver is `ASWebAuthenticationSession`;
/// tests inject a stub so the parse + store can run headlessly.
protocol AppleWebAuthorizationProvider: Sendable {
    /// Presents the consent UI for `authorizationURL` and returns the custom-scheme
    /// callback URL the backend redirected to (carrying `session`/`refresh`/`state`,
    /// or `error`/`state`). `callbackScheme` is the registered custom scheme.
    func callbackURL(authorizationURL: URL, callbackScheme: String) async throws -> URL
}

/// Real Apple web-authorization driver — `ASWebAuthenticationSession` with a
/// custom-scheme redirect. Presents the system browser and follows
/// Apple → backend-callback → `translator-everywhere://` redirect, returning that
/// final URL. This is the only path that touches UI; the parse + token storage
/// after it is plain logic and is fully unit-tested.
final class WebAppleAuthorizationProvider: NSObject, AppleWebAuthorizationProvider, ASWebAuthenticationPresentationContextProviding {

    func callbackURL(authorizationURL: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // ASWebAuthenticationSession is main-actor UI; hop on.
            Task { @MainActor in
                do {
                    let callback = try await self.start(
                        url: authorizationURL,
                        scheme: callbackScheme
                    )
                    continuation.resume(returning: callback)
                } catch {
                    continuation.resume(throwing: Self.map(error))
                }
            }
        }
    }

    @MainActor
    private func start(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: scheme
            ) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? AuthError.cancelled)
                }
            }
            session.presentationContextProvider = self
            // Apple's web flow signs the user in through their existing browser
            // session, so DON'T force an ephemeral session here (unlike Google,
            // where we want a clean PKCE round-trip).
            if !session.start() {
                continuation.resume(throwing: AuthError.providerResponseInvalid)
            }
        }
    }

    private static func map(_ error: Error) -> Error {
        if let asError = error as? ASWebAuthenticationSessionError,
           asError.code == .canceledLogin {
            return AuthError.cancelled
        }
        if let authError = error as? AuthError { return authError }
        return AuthError.transport
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}
