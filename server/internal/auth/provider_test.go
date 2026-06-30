package auth

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// testJWKS spins up an httptest server serving a JWKS for a freshly-generated
// RSA key, and returns a signer for that key.
type testJWKS struct {
	server *httptest.Server
	key    *rsa.PrivateKey
	kid    string
}

func newTestJWKS(t *testing.T) *testJWKS {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	kid := "test-key-1"

	doc := jwksDocument{Keys: []jwk{{
		Kty: "RSA",
		Kid: kid,
		Use: "sig",
		Alg: "RS256",
		N:   base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
		E:   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
	}}}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(doc)
	}))
	t.Cleanup(srv.Close)

	return &testJWKS{server: srv, key: key, kid: kid}
}

func (tj *testJWKS) sign(t *testing.T, claims jwt.MapClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = tj.kid
	signed, err := tok.SignedString(tj.key)
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}
	return signed
}

func (tj *testJWKS) verifier(provider, aud string, issuers []string) *ProviderVerifier {
	return newVerifierWithJWKSURL(provider, tj.server.URL, []string{aud}, issuers, tj.server.Client())
}

func (tj *testJWKS) verifierMulti(provider string, auds, issuers []string) *ProviderVerifier {
	return newVerifierWithJWKSURL(provider, tj.server.URL, auds, issuers, tj.server.Client())
}

// TestProviderVerifyMultipleAudiences covers the Google client-id cutover: a
// verifier configured with two accepted audiences accepts a token minted for
// EITHER, and still rejects a third.
func TestProviderVerifyMultipleAudiences(t *testing.T) {
	const (
		oldAud = "old-client.apps.googleusercontent.com"
		newAud = "new-client.apps.googleusercontent.com"
		iss    = "https://accounts.google.com"
	)
	tj := newTestJWKS(t)
	now := time.Now()
	v := tj.verifierMulti("google", []string{oldAud, newAud}, []string{iss})

	mint := func(aud string) string {
		return tj.sign(t, jwt.MapClaims{
			"iss": iss, "aud": aud, "sub": "u-1",
			"exp": now.Add(time.Hour).Unix(), "iat": now.Unix(),
		})
	}

	for _, aud := range []string{oldAud, newAud} {
		if _, err := v.Verify(context.Background(), mint(aud)); err != nil {
			t.Errorf("aud %q should verify, got %v", aud, err)
		}
	}
	if _, err := v.Verify(context.Background(), mint("third-client.apps.googleusercontent.com")); err == nil {
		t.Error("a token for an unconfigured aud must be rejected")
	}
}

func TestProviderVerify(t *testing.T) {
	const (
		appleAud = "com.cdcupt.translator-everywhere"
		appleIss = "https://appleid.apple.com"
		subject  = "001234.abcdef"
	)
	googleIssuers := []string{"https://accounts.google.com", "accounts.google.com"}

	tj := newTestJWKS(t)
	now := time.Now()

	tests := []struct {
		name      string
		provider  string
		aud       string
		issuers   []string
		claims    jwt.MapClaims
		wantOK    bool
		wantEmail string
	}{
		{
			name:     "valid apple token",
			provider: "apple",
			aud:      appleAud,
			issuers:  []string{appleIss},
			claims: jwt.MapClaims{
				"iss":   appleIss,
				"aud":   appleAud,
				"sub":   subject,
				"email": "erik@example.com",
				"exp":   now.Add(time.Hour).Unix(),
				"iat":   now.Unix(),
			},
			wantOK:    true,
			wantEmail: "erik@example.com",
		},
		{
			name:     "valid google token (bare iss)",
			provider: "google",
			aud:      "client.apps.googleusercontent.com",
			issuers:  googleIssuers,
			claims: jwt.MapClaims{
				"iss": "accounts.google.com",
				"aud": "client.apps.googleusercontent.com",
				"sub": "11223344",
				"exp": now.Add(time.Hour).Unix(),
			},
			wantOK: true,
		},
		{
			name:     "wrong aud",
			provider: "apple",
			aud:      appleAud,
			issuers:  []string{appleIss},
			claims: jwt.MapClaims{
				"iss": appleIss,
				"aud": "com.someone.else",
				"sub": subject,
				"exp": now.Add(time.Hour).Unix(),
			},
			wantOK: false,
		},
		{
			name:     "wrong iss",
			provider: "apple",
			aud:      appleAud,
			issuers:  []string{appleIss},
			claims: jwt.MapClaims{
				"iss": "https://evil.example.com",
				"aud": appleAud,
				"sub": subject,
				"exp": now.Add(time.Hour).Unix(),
			},
			wantOK: false,
		},
		{
			name:     "expired token",
			provider: "apple",
			aud:      appleAud,
			issuers:  []string{appleIss},
			claims: jwt.MapClaims{
				"iss": appleIss,
				"aud": appleAud,
				"sub": subject,
				"exp": now.Add(-time.Hour).Unix(),
			},
			wantOK: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			v := tj.verifier(tt.provider, tt.aud, tt.issuers)
			token := tj.sign(t, tt.claims)

			identity, err := v.Verify(context.Background(), token)
			if tt.wantOK {
				if err != nil {
					t.Fatalf("expected valid, got error: %v", err)
				}
				if identity.Subject != tt.claims["sub"] {
					t.Errorf("subject = %q, want %q", identity.Subject, tt.claims["sub"])
				}
				if identity.Provider != tt.provider {
					t.Errorf("provider = %q, want %q", identity.Provider, tt.provider)
				}
				if identity.Email != tt.wantEmail {
					t.Errorf("email = %q, want %q", identity.Email, tt.wantEmail)
				}
				return
			}
			if err == nil {
				t.Fatalf("expected error, got valid identity %+v", identity)
			}
		})
	}
}

func TestProviderVerifyRejectsWrongSignature(t *testing.T) {
	tj := newTestJWKS(t)

	// Sign with a different key than the one served in the JWKS.
	otherKey, _ := rsa.GenerateKey(rand.Reader, 2048)
	claims := jwt.MapClaims{
		"iss": "https://appleid.apple.com",
		"aud": "com.cdcupt.translator-everywhere",
		"sub": "001",
		"exp": time.Now().Add(time.Hour).Unix(),
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = tj.kid
	signed, err := tok.SignedString(otherKey)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}

	v := tj.verifier("apple", "com.cdcupt.translator-everywhere", []string{"https://appleid.apple.com"})
	if _, err := v.Verify(context.Background(), signed); err == nil {
		t.Fatal("expected signature verification to fail")
	}
}
