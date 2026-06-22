package auth

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	testServicesID  = "com.cdcupt.translator-everywhere.web"
	testRedirectURI = "https://api.translator.daichenlab.com/auth/apple/callback"
	testAppleSub    = "001599.fakeapplesubject.0001"
	testAppleEmail  = "erik@privaterelay.appleid.com"
)

// appleTokenEndpoint mocks Apple's /auth/token. It validates the form fields the
// exchanger must send, then returns an id_token (RS256, signed by tj) for a good
// code or an OAuth error for anything else.
func appleTokenEndpoint(t *testing.T, tj *testJWKS, goodCode string, idClaims jwt.MapClaims) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			http.Error(w, "bad form", http.StatusBadRequest)
			return
		}
		// Assert the request shape the exchanger is contractually required to send.
		if r.Header.Get("Content-Type") != "application/x-www-form-urlencoded" {
			t.Errorf("token request content-type = %q", r.Header.Get("Content-Type"))
		}
		if got := r.Form.Get("grant_type"); got != "authorization_code" {
			t.Errorf("grant_type = %q", got)
		}
		if got := r.Form.Get("client_id"); got != testServicesID {
			t.Errorf("client_id = %q, want %q", got, testServicesID)
		}
		if got := r.Form.Get("redirect_uri"); got != testRedirectURI {
			t.Errorf("redirect_uri = %q", got)
		}
		// client_secret must be a valid ES256 JWT (we don't re-verify the sig here,
		// just confirm it parses with the right alg/claims via the unverified parser).
		assertClientSecret(t, r.Form.Get("client_secret"))

		w.Header().Set("Content-Type", "application/json")
		if r.Form.Get("code") != goodCode {
			_ = json.NewEncoder(w).Encode(map[string]string{
				"error":             "invalid_grant",
				"error_description": "code is expired or revoked",
			})
			return
		}
		idToken := tj.sign(t, idClaims)
		_ = json.NewEncoder(w).Encode(map[string]string{"id_token": idToken})
	}))
	t.Cleanup(srv.Close)
	return srv
}

func assertClientSecret(t *testing.T, raw string) {
	t.Helper()
	if raw == "" {
		t.Fatal("client_secret missing from token request")
	}
	var claims jwt.RegisteredClaims
	parser := jwt.NewParser()
	tok, _, err := parser.ParseUnverified(raw, &claims)
	if err != nil {
		t.Fatalf("client_secret not a JWT: %v", err)
	}
	if alg, _ := tok.Header["alg"].(string); alg != "ES256" {
		t.Errorf("client_secret alg = %q, want ES256", alg)
	}
	if claims.Subject != testServicesID {
		t.Errorf("client_secret sub = %q, want %q", claims.Subject, testServicesID)
	}
	if len(claims.Audience) != 1 || claims.Audience[0] != "https://appleid.apple.com" {
		t.Errorf("client_secret aud = %v", claims.Audience)
	}
}

func newTestAppleOAuth(t *testing.T, tj *testJWKS, tokenURL string) *AppleOAuth {
	t.Helper()
	key, _ := newTestECKey(t)
	secret, err := NewAppleClientSecret(AppleSecretConfig{
		TeamID:     "NK3U2C365Z",
		KeyID:      "TESTKEYID",
		ServicesID: testServicesID,
		PrivateKey: key,
	})
	if err != nil {
		t.Fatalf("client secret: %v", err)
	}
	verifier := NewAppleVerifierWithJWKS(tj.server.URL, testServicesID, "https://appleid.apple.com", tj.server.Client())

	oauth, err := NewAppleOAuth(AppleOAuthConfig{
		ServicesID:  testServicesID,
		RedirectURI: testRedirectURI,
		TokenURL:    tokenURL,
		Secret:      secret,
		Verifier:    verifier,
		HTTPClient:  &http.Client{Timeout: 5 * time.Second},
	})
	if err != nil {
		t.Fatalf("new apple oauth: %v", err)
	}
	return oauth
}

func validIDClaims() jwt.MapClaims {
	now := time.Now()
	return jwt.MapClaims{
		"iss":   "https://appleid.apple.com",
		"aud":   testServicesID,
		"sub":   testAppleSub,
		"email": testAppleEmail,
		"exp":   now.Add(time.Hour).Unix(),
		"iat":   now.Unix(),
	}
}

func TestAppleOAuthExchangeHappyPath(t *testing.T) {
	tj := newTestJWKS(t)
	tokenSrv := appleTokenEndpoint(t, tj, "good-code", validIDClaims())
	oauth := newTestAppleOAuth(t, tj, tokenSrv.URL)

	identity, err := oauth.ExchangeCode(context.Background(), "good-code")
	if err != nil {
		t.Fatalf("exchange: %v", err)
	}
	if identity.Provider != "apple" {
		t.Errorf("provider = %q, want apple", identity.Provider)
	}
	if identity.Subject != testAppleSub {
		t.Errorf("subject = %q, want %q", identity.Subject, testAppleSub)
	}
	if identity.Email != testAppleEmail {
		t.Errorf("email = %q, want %q", identity.Email, testAppleEmail)
	}
}

func TestAppleOAuthExchangeBadCode(t *testing.T) {
	tj := newTestJWKS(t)
	tokenSrv := appleTokenEndpoint(t, tj, "good-code", validIDClaims())
	oauth := newTestAppleOAuth(t, tj, tokenSrv.URL)

	if _, err := oauth.ExchangeCode(context.Background(), "expired-code"); err == nil {
		t.Fatal("expected error for bad/expired code")
	}
}

func TestAppleOAuthExchangeEmptyCode(t *testing.T) {
	tj := newTestJWKS(t)
	tokenSrv := appleTokenEndpoint(t, tj, "good-code", validIDClaims())
	oauth := newTestAppleOAuth(t, tj, tokenSrv.URL)

	if _, err := oauth.ExchangeCode(context.Background(), ""); err == nil {
		t.Fatal("expected error for empty code")
	}
}

func TestAppleOAuthExchangeRejectsExpiredIDToken(t *testing.T) {
	tj := newTestJWKS(t)
	claims := validIDClaims()
	claims["exp"] = time.Now().Add(-time.Hour).Unix() // expired id_token
	tokenSrv := appleTokenEndpoint(t, tj, "good-code", claims)
	oauth := newTestAppleOAuth(t, tj, tokenSrv.URL)

	if _, err := oauth.ExchangeCode(context.Background(), "good-code"); err == nil {
		t.Fatal("expected id_token verification to reject an expired token")
	}
}

func TestAppleOAuthExchangeRejectsWrongAudience(t *testing.T) {
	tj := newTestJWKS(t)
	claims := validIDClaims()
	claims["aud"] = "com.someone.else" // not our Services ID
	tokenSrv := appleTokenEndpoint(t, tj, "good-code", claims)
	oauth := newTestAppleOAuth(t, tj, tokenSrv.URL)

	if _, err := oauth.ExchangeCode(context.Background(), "good-code"); err == nil {
		t.Fatal("expected id_token verification to reject a wrong audience")
	}
}

func TestNewAppleOAuthValidates(t *testing.T) {
	key, _ := newTestECKey(t)
	secret, _ := NewAppleClientSecret(AppleSecretConfig{
		TeamID: "T", KeyID: "K", ServicesID: "S", PrivateKey: key,
	})
	verifier := NewAppleVerifier("S", "https://appleid.apple.com", http.DefaultClient)

	if _, err := NewAppleOAuth(AppleOAuthConfig{RedirectURI: "r", Secret: secret, Verifier: verifier}); err == nil {
		t.Error("expected error for missing services id")
	}
	if _, err := NewAppleOAuth(AppleOAuthConfig{ServicesID: "s", Secret: secret, Verifier: verifier}); err == nil {
		t.Error("expected error for missing redirect uri")
	}
	if _, err := NewAppleOAuth(AppleOAuthConfig{ServicesID: "s", RedirectURI: "r", Verifier: verifier}); err == nil {
		t.Error("expected error for missing secret")
	}
	if _, err := NewAppleOAuth(AppleOAuthConfig{ServicesID: "s", RedirectURI: "r", Secret: secret}); err == nil {
		t.Error("expected error for missing verifier")
	}

	ok, err := NewAppleOAuth(AppleOAuthConfig{ServicesID: "s", RedirectURI: "r", Secret: secret, Verifier: verifier})
	if err != nil {
		t.Fatalf("valid config should succeed: %v", err)
	}
	if ok.tokenURL != AppleTokenURL {
		t.Errorf("tokenURL default = %q, want %q", ok.tokenURL, AppleTokenURL)
	}
}
