import CryptoKit
import Foundation
import Testing
@testable import Translator_Everywhere

@Suite("PKCE — RFC 7636 verifier / challenge")
struct PKCETests {

    /// The canonical RFC-7636 Appendix-B test vector: a known verifier maps to a
    /// known `S256` challenge.
    @Test("S256 challenge matches the RFC-7636 Appendix-B vector")
    func rfcVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        #expect(PKCE.challenge(for: verifier) == expected)
    }

    @Test("challenge is base64url with no padding and no +/ characters")
    func base64URLShape() {
        let pkce = PKCE()
        #expect(!pkce.codeChallenge.contains("="))
        #expect(!pkce.codeChallenge.contains("+"))
        #expect(!pkce.codeChallenge.contains("/"))
        #expect(pkce.method == "S256")
    }

    @Test("challenge equals BASE64URL(SHA256(verifier)) recomputed independently")
    func challengeIsSelfConsistent() {
        let pkce = PKCE()
        let digest = SHA256.hash(data: Data(pkce.codeVerifier.utf8))
        let recomputed = PKCE.base64URLEncode(Data(digest))
        #expect(pkce.codeChallenge == recomputed)
    }

    @Test("each PKCE has a distinct, sufficiently long verifier and state")
    func freshnessAndEntropy() {
        let a = PKCE()
        let b = PKCE()
        #expect(a.codeVerifier != b.codeVerifier)
        #expect(a.state != b.state)
        // RFC 7636 requires 43–128 chars; 32 random bytes → 43 base64url chars.
        #expect(a.codeVerifier.count >= 43)
    }

    @Test("explicit-verifier initializer derives the matching challenge")
    func explicitInit() {
        let pkce = PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "xyz")
        #expect(pkce.codeChallenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(pkce.state == "xyz")
    }
}
