import Foundation

/// Persists the auth session. Tokens (session JWT + refresh) go to the Keychain
/// via `KeychainStore`; the non-secret display `user` is mirrored in
/// `UserDefaults` so the Account tab can render "signed in as …" without
/// touching the Keychain on every read.
///
/// Sign-out clears the tokens (and the user mirror) but never touches the local
/// notebook — per DESIGN §2e, signing out keeps your vocabulary on this Mac.
final class TokenStore {

    /// Keychain accounts for the two session tokens (distinct from the OpenAI
    /// key account, same service scope).
    static let sessionJWTAccount = "auth-session-jwt"
    static let refreshTokenAccount = "auth-refresh-token"

    private enum DefaultsKey {
        static let userID = "auth.user.id"
        static let userEmail = "auth.user.email"
        static let userProvider = "auth.user.provider"
    }

    private let keychain: KeychainStore
    private let defaults: UserDefaults

    init(keychain: KeychainStore = KeychainStore(), defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
    }

    /// The current session, or `nil` when signed out. Reads both tokens from the
    /// Keychain plus the mirrored user; any missing piece means signed-out.
    func load() -> AuthSession? {
        guard let jwt = keychain.string(for: Self.sessionJWTAccount),
              let refresh = keychain.string(for: Self.refreshTokenAccount),
              let id = defaults.string(forKey: DefaultsKey.userID),
              let providerRaw = defaults.string(forKey: DefaultsKey.userProvider),
              let provider = AuthProvider(rawValue: providerRaw)
        else {
            return nil
        }
        let email = defaults.string(forKey: DefaultsKey.userEmail)
        let user = AuthUser(id: id, email: email, provider: provider)
        return AuthSession(sessionJWT: jwt, refreshToken: refresh, user: user)
    }

    /// Persists a full session (after sign-in). Overwrites any prior tokens.
    func save(_ session: AuthSession) throws {
        try keychain.set(session.sessionJWT, for: Self.sessionJWTAccount)
        try keychain.set(session.refreshToken, for: Self.refreshTokenAccount)
        defaults.set(session.user.id, forKey: DefaultsKey.userID)
        defaults.set(session.user.email, forKey: DefaultsKey.userEmail)
        defaults.set(session.user.provider.rawValue, forKey: DefaultsKey.userProvider)
    }

    /// Swaps in a fresh access JWT after `/auth/refresh`, keeping the refresh
    /// token and user untouched.
    func updateSessionJWT(_ jwt: String) throws {
        try keychain.set(jwt, for: Self.sessionJWTAccount)
    }

    /// Clears both tokens and the user mirror. The local notebook is untouched.
    func clear() throws {
        try keychain.delete(Self.sessionJWTAccount)
        try keychain.delete(Self.refreshTokenAccount)
        defaults.removeObject(forKey: DefaultsKey.userID)
        defaults.removeObject(forKey: DefaultsKey.userEmail)
        defaults.removeObject(forKey: DefaultsKey.userProvider)
    }
}
