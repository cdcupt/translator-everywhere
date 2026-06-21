import Foundation

/// Sign-in via AuthenticationServices (TECH §8.6).
///
/// Apple via `ASAuthorizationController`; Google via
/// `ASWebAuthenticationSession` + PKCE. Exchanges the provider token for our
/// session JWT, then hands the tokens to `KeychainStore`. Optional — the app
/// works fully without it. Stub for slice 1.
final class AuthClient {
    func signInWithApple() async throws {
        // TODO(slice: auth): ASAuthorizationController flow.
    }

    func signInWithGoogle() async throws {
        // TODO(slice: auth): ASWebAuthenticationSession + PKCE flow.
    }
}
