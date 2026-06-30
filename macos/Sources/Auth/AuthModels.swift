import Foundation

/// Public sign-in / sync configuration (CONFIG.md). All values here are public
/// identifiers safe to ship in the binary — no secrets.
enum AuthConfig {

    /// Our backend base URL. Every auth + sync call hangs off this.
    static let backendBaseURL = URL(string: "https://api.translator.daichenlab.com")!

    /// Google OAuth **Desktop app** client id (PKCE + loopback, no client secret
    /// on device). This is the Translator-Everywhere-branded Desktop client in
    /// TE's own GCP project (`524726675699`). It replaced `328818408791-641sqb…`,
    /// which lived in **BillMind's** project (wrong consent-screen brand) and was
    /// an iOS-type client whose custom-scheme redirect desktop Chrome dropped.
    static let googleClientID = "524726675699-vnleiirk1tj2rpa5eic7nj617j5p8rlu.apps.googleusercontent.com"

    /// Google authorization + token endpoints (OAuth 2.0).
    static let googleAuthorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let googleTokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// The redirect path the loopback listener serves. The full `redirect_uri`
    /// (`http://127.0.0.1:<ephemeral-port>/oauth2redirect`) is built at runtime by
    /// `LoopbackRedirectListener` once it binds, then threaded into BOTH the
    /// authorize URL and the token exchange (Google requires them identical).
    static let googleRedirectPath = "/oauth2redirect"

    /// Scopes — `openid email` is enough to mint the id_token our server needs.
    static let googleScope = "openid email profile"

    // MARK: - Apple (Sign in with Apple — WEB flow)

    /// Apple OAuth **Services ID** used as the `client_id` for the web flow.
    /// This is the Services ID registered in the Apple Developer portal (NOT the
    /// app's bundle id), with `redirect_uri` `appleRedirectURI` registered on it.
    // TODO(coordinator): confirm real Services ID.
    static let appleServicesID = "com.cdcupt.translator-everywhere.web"

    /// Apple's web authorization endpoint (OAuth 2.0 / OIDC).
    static let appleAuthorizationEndpoint = URL(string: "https://appleid.apple.com/auth/authorize")!

    /// `redirect_uri` registered on the Services ID — our backend's callback. The
    /// backend exchanges Apple's `code` for the id_token, mints our session, then
    /// 302s back to the app via `appleCallbackScheme`.
    static let appleRedirectURI = "https://api.translator.daichenlab.com/auth/apple/callback"

    /// Custom URL scheme the backend redirects to after a successful (or failed)
    /// Apple sign-in. Registered in the app's `CFBundleURLTypes` (project.yml) so
    /// the browser routes the redirect back into the app (`WebAuthRouter`).
    static let appleCallbackScheme = "translator-everywhere"

    /// Scopes requested from Apple. `name email` is what our backend needs to
    /// build the user; Apple returns these only on the first authorization.
    static let appleScope = "name email"
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
