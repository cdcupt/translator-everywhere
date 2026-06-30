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
	testGoogleClientID = "524726675699-test.apps.googleusercontent.com"
	testGoogleSecret   = "GOCSPX-test-secret"
	testGoogleRedirect = "http://127.0.0.1:51234/oauth2redirect"
	testGoogleSub      = "11223344556677889900"
	testGoogleEmail    = "erik@gmail.com"
)

var testGoogleIssuers = []string{"https://accounts.google.com", "accounts.google.com"}

// googleTokenEndpoint mocks Google's /token. It asserts the exact form fields the
// exchanger must send (incl. client_secret + code_verifier + redirect_uri), then
// returns a tj-signed id_token for the good code or an OAuth error otherwise.
func googleTokenEndpoint(t *testing.T, tj *testJWKS, goodCode string, idClaims jwt.MapClaims) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			http.Error(w, "bad form", http.StatusBadRequest)
			return
		}
		if got := r.Form.Get("grant_type"); got != "authorization_code" {
			t.Errorf("grant_type = %q", got)
		}
		if got := r.Form.Get("client_id"); got != testGoogleClientID {
			t.Errorf("client_id = %q", got)
		}
		if got := r.Form.Get("client_secret"); got != testGoogleSecret {
			t.Errorf("client_secret = %q, want %q", got, testGoogleSecret)
		}
		if got := r.Form.Get("redirect_uri"); got != testGoogleRedirect {
			t.Errorf("redirect_uri = %q", got)
		}
		if r.Form.Get("code_verifier") == "" {
			t.Error("code_verifier missing")
		}
		w.Header().Set("Content-Type", "application/json")
		if r.Form.Get("code") != goodCode {
			_ = json.NewEncoder(w).Encode(map[string]string{
				"error": "invalid_grant", "error_description": "bad code",
			})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"id_token": tj.sign(t, idClaims)})
	}))
	t.Cleanup(srv.Close)
	return srv
}

func newTestGoogleOAuth(t *testing.T, tj *testJWKS, tokenURL string) *GoogleOAuth {
	t.Helper()
	verifier := newVerifierWithJWKSURL("google", tj.server.URL, []string{testGoogleClientID}, testGoogleIssuers, tj.server.Client())
	oauth, err := NewGoogleOAuth(GoogleOAuthConfig{
		ClientID:     testGoogleClientID,
		ClientSecret: testGoogleSecret,
		TokenURL:     tokenURL,
		Verifier:     verifier,
		HTTPClient:   &http.Client{Timeout: 5 * time.Second},
	})
	if err != nil {
		t.Fatalf("new google oauth: %v", err)
	}
	return oauth
}

func validGoogleIDClaims() jwt.MapClaims {
	now := time.Now()
	return jwt.MapClaims{
		"iss":   "https://accounts.google.com",
		"aud":   testGoogleClientID,
		"sub":   testGoogleSub,
		"email": testGoogleEmail,
		"exp":   now.Add(time.Hour).Unix(),
		"iat":   now.Unix(),
	}
}

func TestGoogleOAuthExchangeHappyPath(t *testing.T) {
	tj := newTestJWKS(t)
	tokenSrv := googleTokenEndpoint(t, tj, "good-code", validGoogleIDClaims())
	oauth := newTestGoogleOAuth(t, tj, tokenSrv.URL)

	identity, err := oauth.ExchangeCode(context.Background(), "good-code", "verifier-xyz", testGoogleRedirect)
	if err != nil {
		t.Fatalf("exchange: %v", err)
	}
	if identity.Provider != "google" || identity.Subject != testGoogleSub || identity.Email != testGoogleEmail {
		t.Errorf("identity = %+v", identity)
	}
}

func TestGoogleOAuthExchangeBadCode(t *testing.T) {
	tj := newTestJWKS(t)
	tokenSrv := googleTokenEndpoint(t, tj, "good-code", validGoogleIDClaims())
	oauth := newTestGoogleOAuth(t, tj, tokenSrv.URL)
	if _, err := oauth.ExchangeCode(context.Background(), "bad-code", "v", testGoogleRedirect); err == nil {
		t.Fatal("expected error for bad code")
	}
}

func TestGoogleOAuthExchangeMissingArgs(t *testing.T) {
	tj := newTestJWKS(t)
	tokenSrv := googleTokenEndpoint(t, tj, "good-code", validGoogleIDClaims())
	oauth := newTestGoogleOAuth(t, tj, tokenSrv.URL)
	if _, err := oauth.ExchangeCode(context.Background(), "", "v", testGoogleRedirect); err == nil {
		t.Error("expected error for empty code")
	}
	if _, err := oauth.ExchangeCode(context.Background(), "c", "", testGoogleRedirect); err == nil {
		t.Error("expected error for empty verifier")
	}
	if _, err := oauth.ExchangeCode(context.Background(), "c", "v", ""); err == nil {
		t.Error("expected error for empty redirect_uri")
	}
}

func TestGoogleOAuthExchangeRejectsWrongAudience(t *testing.T) {
	tj := newTestJWKS(t)
	claims := validGoogleIDClaims()
	claims["aud"] = "some-other-client.apps.googleusercontent.com"
	tokenSrv := googleTokenEndpoint(t, tj, "good-code", claims)
	oauth := newTestGoogleOAuth(t, tj, tokenSrv.URL)
	if _, err := oauth.ExchangeCode(context.Background(), "good-code", "v", testGoogleRedirect); err == nil {
		t.Fatal("expected verification to reject a wrong audience")
	}
}

func TestNewGoogleOAuthValidates(t *testing.T) {
	v := NewGoogleVerifier([]string{"c"}, testGoogleIssuers, http.DefaultClient)
	if _, err := NewGoogleOAuth(GoogleOAuthConfig{ClientSecret: "s", Verifier: v}); err == nil {
		t.Error("expected error for missing client id")
	}
	if _, err := NewGoogleOAuth(GoogleOAuthConfig{ClientID: "c", Verifier: v}); err == nil {
		t.Error("expected error for missing client secret")
	}
	if _, err := NewGoogleOAuth(GoogleOAuthConfig{ClientID: "c", ClientSecret: "s"}); err == nil {
		t.Error("expected error for missing verifier")
	}
	ok, err := NewGoogleOAuth(GoogleOAuthConfig{ClientID: "c", ClientSecret: "s", Verifier: v})
	if err != nil {
		t.Fatalf("valid config should succeed: %v", err)
	}
	if ok.tokenURL != GoogleTokenURL {
		t.Errorf("tokenURL default = %q, want %q", ok.tokenURL, GoogleTokenURL)
	}
}
