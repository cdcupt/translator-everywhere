import AppKit
import AuthenticationServices
import Foundation

/// Real Google authorization driver — `ASWebAuthenticationSession` with a
/// loopback / custom-scheme redirect. Presents the system browser, waits for the
/// redirect, validates `state`, and pulls out the `code`. This is the only path
/// that touches UI; everything after (token exchange, backend POST) is plain
/// networking and is fully unit-tested.
final class WebGoogleAuthorizationProvider: NSObject, GoogleAuthorizationProvider, ASWebAuthenticationPresentationContextProviding {

    func authorizationCode(
        authorizationURL: URL,
        redirectScheme: String,
        expectedState: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // ASWebAuthenticationSession is main-actor UI; hop on.
            Task { @MainActor in
                let callbackURL: URL
                do {
                    callbackURL = try await self.start(
                        url: authorizationURL,
                        scheme: redirectScheme
                    )
                } catch {
                    continuation.resume(throwing: Self.map(error))
                    return
                }
                do {
                    let code = try Self.extractCode(from: callbackURL, expectedState: expectedState)
                    continuation.resume(returning: code)
                } catch {
                    continuation.resume(throwing: error)
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
            session.prefersEphemeralWebBrowserSession = true
            if !session.start() {
                continuation.resume(throwing: AuthError.providerResponseInvalid)
            }
        }
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

    private static func map(_ error: Error) -> Error {
        if let asError = error as? ASWebAuthenticationSessionError,
           asError.code == .canceledLogin {
            return AuthError.cancelled
        }
        if let authError = error as? AuthError { return authError }
        return AuthError.transport
    }

    /// Anchors the auth UI to the app's real on-screen window (the Preferences
    /// window the user signed in from). Returning a throwaway `ASPresentationAnchor()`
    /// — a never-shown `NSWindow` — makes `ASWebAuthenticationSession` fail to
    /// present: its completion handler never fires, the continuation never
    /// resumes, and the Account tab is stuck on "signing in…" forever. In this
    /// `LSUIElement` agent app there is no main window, so resolve the visible
    /// window explicitly. The system invokes this on the main thread, so reading
    /// `NSApp` here is safe.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
            ?? ASPresentationAnchor()
    }
}
