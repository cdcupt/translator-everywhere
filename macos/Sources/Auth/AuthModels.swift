import Foundation

/// Public sign-in / sync configuration (CONFIG.md). All values here are public
/// identifiers safe to ship in the binary — no secrets.
enum AuthConfig {

    /// Our backend base URL. Every auth + sync call hangs off this.
    static let backendBaseURL = URL(string: "https://api.translator.daichenlab.com")!

    /// Google OAuth *Desktop app* client id (PKCE, no client secret on device).
    static let googleClientID =
        "328818408791-641sqb2v2smjgjud26e87j7rhnfo0uem.apps.googleusercontent.com"

    /// Google authorization + token endpoints (OAuth 2.0).
    static let googleAuthorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let googleTokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// Loopback redirect scheme for the Desktop OAuth flow. Google accepts a
    /// reverse-DNS custom scheme derived from the client id for installed apps.
    static let googleRedirectScheme =
        "com.googleusercontent.apps.328818408791-641sqb2v2smjgjud26e87j7rhnfo0uem"

    /// Full redirect URI handed to `ASWebAuthenticationSession`.
    static var googleRedirectURI: String { "\(googleRedirectScheme):/oauth2redirect" }

    /// Scopes — `openid email` is enough to mint the id_token our server needs.
    static let googleScope = "openid email profile"
}

/// Which provider minted the current session — display only.
enum AuthProvider: String, Codable, Sendable, Equatable {
    case apple
    case google
}

/// The signed-in user as our server reports it (TECH §7 `user` object).
struct AuthUser: Codable, Sendable, Equatable {
    let id: String
    let email: String?
    let provider: AuthProvider
}

/// Our session as stored on-device: the short-lived access JWT, the long-lived
/// refresh token, and the display user. Persisted in the Keychain (tokens) +
/// a small UserDefaults mirror (non-secret user display fields).
struct AuthSession: Sendable, Equatable {
    let sessionJWT: String
    let refreshToken: String
    let user: AuthUser
}

// MARK: - Wire types (match the server JSON exactly — see server/internal/api)

/// `POST /auth/google` request body.
struct GoogleSignInRequest: Encodable {
    let idToken: String
    enum CodingKeys: String, CodingKey { case idToken = "id_token" }
}

/// `POST /auth/apple` request body.
struct AppleSignInRequest: Encodable {
    let identityToken: String
    enum CodingKeys: String, CodingKey { case identityToken = "identity_token" }
}

/// `POST /auth/refresh` request body.
struct RefreshRequest: Encodable {
    let refreshToken: String
    enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
}

/// `POST /auth/{provider}` response.
struct SessionResponse: Decodable {
    let sessionJWT: String
    let refreshToken: String
    let user: AuthUser

    enum CodingKeys: String, CodingKey {
        case sessionJWT = "session_jwt"
        case refreshToken = "refresh_token"
        case user
    }
}

/// `POST /auth/refresh` response.
struct RefreshResponse: Decodable {
    let sessionJWT: String
    enum CodingKeys: String, CodingKey { case sessionJWT = "session_jwt" }
}

/// Google `POST /token` response (PKCE exchange). We only need `id_token`.
struct GoogleTokenResponse: Decodable {
    let idToken: String
    let accessToken: String?
    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
    }
}

/// Errors surfaced by `AuthClient`. UI maps these to DESIGN §4 copy.
enum AuthError: Error, Equatable {
    /// The user dismissed the system sign-in sheet / browser.
    case cancelled
    /// The provider redirect was malformed or carried an error / state mismatch.
    case providerResponseInvalid
    /// Our backend (or Google's token endpoint) returned a non-2xx status.
    case server(status: Int)
    /// A response body could not be decoded.
    case decoding
    /// Refresh failed — caller drops to signed-out.
    case refreshFailed
    /// No session is present where one was required.
    case notSignedIn
    /// Transport failure.
    case transport
}
