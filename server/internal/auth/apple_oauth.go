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

// AppleTokenURL is Apple's OAuth token endpoint.
const AppleTokenURL = "https://appleid.apple.com/auth/token"

// IDTokenVerifier verifies a provider id_token (Apple JWKS-backed). The package
// ProviderVerifier satisfies this; tests substitute a fake.
type IDTokenVerifier interface {
	Verify(ctx context.Context, rawToken string) (Identity, error)
}

// AppleOAuth runs the Sign in with Apple WEB flow's server side: it exchanges
// the authorization code Apple hands back for an id_token, then verifies that
// id_token to obtain the user's stable subject + email.
type AppleOAuth struct {
	servicesID  string // OAuth client_id (the Apple Services ID)
	redirectURI string // must match the URI registered on the Services ID
	tokenURL    string // Apple token endpoint (overridable in tests)
	secret      *AppleClientSecret
	verifier    IDTokenVerifier
	httpClient  *http.Client
}

// AppleOAuthConfig wires the OAuth exchanger.
type AppleOAuthConfig struct {
	ServicesID  string
	RedirectURI string
	TokenURL    string // optional; defaults to AppleTokenURL
	Secret      *AppleClientSecret
	Verifier    IDTokenVerifier
	HTTPClient  *http.Client
}

// NewAppleOAuth validates the config and returns the exchanger.
func NewAppleOAuth(cfg AppleOAuthConfig) (*AppleOAuth, error) {
	if cfg.ServicesID == "" {
		return nil, errors.New("auth: apple oauth needs a services id")
	}
	if cfg.RedirectURI == "" {
		return nil, errors.New("auth: apple oauth needs a redirect uri")
	}
	if cfg.Secret == nil {
		return nil, errors.New("auth: apple oauth needs a client_secret builder")
	}
	if cfg.Verifier == nil {
		return nil, errors.New("auth: apple oauth needs an id_token verifier")
	}
	tokenURL := cfg.TokenURL
	if tokenURL == "" {
		tokenURL = AppleTokenURL
	}
	client := cfg.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	return &AppleOAuth{
		servicesID:  cfg.ServicesID,
		redirectURI: cfg.RedirectURI,
		tokenURL:    tokenURL,
		secret:      cfg.Secret,
		verifier:    cfg.Verifier,
		httpClient:  client,
	}, nil
}

// appleTokenResponse is the subset of Apple's /auth/token response we consume.
type appleTokenResponse struct {
	IDToken          string `json:"id_token"`
	Error            string `json:"error"`
	ErrorDescription string `json:"error_description"`
}

// ExchangeCode trades the authorization code for an id_token at Apple's token
// endpoint, verifies that id_token, and returns the resulting Identity.
func (a *AppleOAuth) ExchangeCode(ctx context.Context, code string) (Identity, error) {
	if code == "" {
		return Identity{}, errors.New("auth: apple oauth: empty authorization code")
	}

	clientSecret, err := a.secret.Generate()
	if err != nil {
		return Identity{}, err
	}

	form := url.Values{
		"client_id":     {a.servicesID},
		"client_secret": {clientSecret},
		"code":          {code},
		"grant_type":    {"authorization_code"},
		"redirect_uri":  {a.redirectURI},
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return Identity{}, fmt.Errorf("auth: apple oauth: build token request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	resp, err := a.httpClient.Do(req)
	if err != nil {
		return Identity{}, fmt.Errorf("auth: apple oauth: token request: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return Identity{}, fmt.Errorf("auth: apple oauth: read token response: %w", err)
	}

	var tok appleTokenResponse
	if err := json.Unmarshal(body, &tok); err != nil {
		return Identity{}, fmt.Errorf("auth: apple oauth: decode token response (status %d): %w", resp.StatusCode, err)
	}
	if tok.Error != "" {
		return Identity{}, fmt.Errorf("auth: apple oauth: token endpoint error %q: %s", tok.Error, tok.ErrorDescription)
	}
	if resp.StatusCode != http.StatusOK {
		return Identity{}, fmt.Errorf("auth: apple oauth: token endpoint returned %d", resp.StatusCode)
	}
	if tok.IDToken == "" {
		return Identity{}, errors.New("auth: apple oauth: token response missing id_token")
	}

	identity, err := a.verifier.Verify(ctx, tok.IDToken)
	if err != nil {
		return Identity{}, fmt.Errorf("auth: apple oauth: verify id_token: %w", err)
	}
	return identity, nil
}
