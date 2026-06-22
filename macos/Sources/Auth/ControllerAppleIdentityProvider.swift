import AuthenticationServices
import Foundation

/// Real Sign in with Apple driver — `ASAuthorizationController` with
/// `ASAuthorizationAppleIDProvider`. Returns the identity-token JWT our backend
/// verifies against Apple's JWKS.
///
/// IMPORTANT: this only works at runtime once the app is code-signed with the
/// `com.apple.developer.applesignin` entitlement (slice 8). Until then the
/// controller fails immediately with `.unknown` / no credential — that's
/// expected. It is here so the flow COMPILES and mirrors Google; the headless
/// tests drive `AuthClient.signInWithApple()` through an injected stub instead.
final class ControllerAppleIdentityProvider: NSObject, AppleIdentityProvider, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    // Pin the continuation across the delegate callbacks for one request.
    private var continuation: CheckedContinuation<String, Error>?

    func identityToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.continuation = continuation
                let request = ASAuthorizationAppleIDProvider().createRequest()
                request.requestedScopes = [.email]
                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        defer { continuation = nil }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8)
        else {
            continuation?.resume(throwing: AuthError.providerResponseInvalid)
            return
        }
        continuation?.resume(returning: token)
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        defer { continuation = nil }
        if let asError = error as? ASAuthorizationError, asError.code == .canceled {
            continuation?.resume(throwing: AuthError.cancelled)
        } else {
            continuation?.resume(throwing: AuthError.providerResponseInvalid)
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}
