import CryptoKit
import Foundation

/// PKCE (RFC 7636) parameters for the Google OAuth Authorization-Code flow.
///
/// A native app has no safe place for a client secret, so we use Proof Key for
/// Code Exchange: generate a high-entropy `codeVerifier`, send only its SHA-256
/// `codeChallenge` (base64url, `S256`) up front, then prove possession by
/// presenting the verifier at token exchange. A `state` value guards against
/// CSRF / response mix-up on the loopback redirect.
struct PKCE: Equatable {

    /// The secret kept on-device and presented at token exchange.
    let codeVerifier: String

    /// `BASE64URL(SHA256(codeVerifier))` — sent on the authorization request.
    let codeChallenge: String

    /// The challenge method; always `S256` (plain is not used).
    let method = "S256"

    /// Opaque anti-CSRF token echoed back on the redirect and re-checked.
    let state: String

    /// Generates a fresh verifier/challenge/state from cryptographic randomness.
    init() {
        let verifier = Self.randomURLSafeToken(byteCount: 32)
        self.codeVerifier = verifier
        self.codeChallenge = Self.challenge(for: verifier)
        self.state = Self.randomURLSafeToken(byteCount: 16)
    }

    /// Test/explicit initializer — derives the challenge from a supplied
    /// verifier so the SHA-256 + base64url math can be asserted against known
    /// vectors.
    init(codeVerifier: String, state: String) {
        self.codeVerifier = codeVerifier
        self.codeChallenge = Self.challenge(for: codeVerifier)
        self.state = state
    }

    /// `BASE64URL(SHA256(ascii(verifier)))` with no padding — the RFC-7636
    /// `S256` transformation.
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    /// A base64url-encoded token from `byteCount` random bytes. The encoded
    /// string is itself a valid `code_verifier` (RFC-7636 unreserved charset).
    static func randomURLSafeToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            // Fallback to the system RNG; still cryptographically suitable here.
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return base64URLEncode(Data(bytes))
    }

    /// Base64url without padding (`+`→`-`, `/`→`_`, drop `=`) per RFC 7636 §A.
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
