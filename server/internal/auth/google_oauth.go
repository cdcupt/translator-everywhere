package auth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// GoogleTokenURL is Google's OAuth token endpoint.
const GoogleTokenURL = "https://oauth2.googleapis.com/token"

// GoogleOAuth runs the server side of the Google **Desktop-app loopback + PKCE**
// flow: it exchanges the authorization code the app captured on localhost for an
// id_token, then verifies that id_token to obtain the user's stable subject +
// email.
//
// The exchange lives on the server (not in the app) because Google's token
// endpoint requires the Desktop client's client_secret even with PKCE — keeping
// it here means the secret never ships in the (public-repo, distributable) app.
type GoogleOAuth struct {
	clientID     string
	clientSecret string
	tokenURL     string // overridable in tests
	verifier     IDTokenVerifier
	httpClient   *http.Client
}

// GoogleOAuthConfig wires the exchanger.
type GoogleOAuthConfig struct {
	ClientID     string
	ClientSecret string
	TokenURL     string // optional; defaults to GoogleTokenURL
	Verifier     IDTokenVerifier
	HTTPClient   *http.Client
}

// NewGoogleOAuth validates the config and returns the exchanger.
func NewGoogleOAuth(cfg GoogleOAuthConfig) (*GoogleOAuth, error) {
	if cfg.ClientID == "" {
		return nil, errors.New("auth: google oauth needs a client id")
	}
	if cfg.ClientSecret == "" {
		return nil, errors.New("auth: google oauth needs a client secret")
	}
	if cfg.Verifier == nil {
		return nil, errors.New("auth: google oauth needs an id_token verifier")
	}
	tokenURL := cfg.TokenURL
	if tokenURL == "" {
		tokenURL = GoogleTokenURL
	}
	client := cfg.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	return &GoogleOAuth{
		clientID:     cfg.ClientID,
		clientSecret: cfg.ClientSecret,
		tokenURL:     tokenURL,
		verifier:     cfg.Verifier,
		httpClient:   client,
	}, nil
}

// googleTokenResponse is the subset of Google's /token response we consume.
type googleTokenResponse struct {
	IDToken          string `json:"id_token"`
	Error            string `json:"error"`
	ErrorDescription string `json:"error_description"`
}

// ExchangeCode trades the authorization code (with its PKCE verifier and the
// exact loopback redirect_uri the app used) for an id_token at Google's token
// endpoint, verifies that id_token, and returns the resulting Identity.
func (g *GoogleOAuth) ExchangeCode(ctx context.Context, code, codeVerifier, redirectURI string) (Identity, error) {
	if code == "" {
		return Identity{}, errors.New("auth: google oauth: empty authorization code")
	}
	if codeVerifier == "" || redirectURI == "" {
		return Identity{}, errors.New("auth: google oauth: missing code_verifier or redirect_uri")
	}

	form := url.Values{
		"client_id":     {g.clientID},
		"client_secret": {g.clientSecret},
		"code":          {code},
		"code_verifier": {codeVerifier},
		"grant_type":    {"authorization_code"},
		"redirect_uri":  {redirectURI},
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return Identity{}, fmt.Errorf("auth: google oauth: build token request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	resp, err := g.httpClient.Do(req)
	if err != nil {
		return Identity{}, fmt.Errorf("auth: google oauth: token request: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return Identity{}, fmt.Errorf("auth: google oauth: read token response: %w", err)
	}

	var tok googleTokenResponse
	if err := json.Unmarshal(body, &tok); err != nil {
		return Identity{}, fmt.Errorf("auth: google oauth: decode token response (status %d): %w", resp.StatusCode, err)
	}
	if tok.Error != "" {
		return Identity{}, fmt.Errorf("auth: google oauth: token endpoint error %q: %s", tok.Error, tok.ErrorDescription)
	}
	if resp.StatusCode != http.StatusOK {
		return Identity{}, fmt.Errorf("auth: google oauth: token endpoint returned %d", resp.StatusCode)
	}
	if tok.IDToken == "" {
		return Identity{}, errors.New("auth: google oauth: token response missing id_token")
	}

	identity, err := g.verifier.Verify(ctx, tok.IDToken)
	if err != nil {
		return Identity{}, fmt.Errorf("auth: google oauth: verify id_token: %w", err)
	}
	return identity, nil
}
