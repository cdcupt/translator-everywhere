package auth

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Default provider JWKS endpoints.
const (
	AppleJWKSURL  = "https://appleid.apple.com/auth/keys"
	GoogleJWKSURL = "https://www.googleapis.com/oauth2/v3/certs"

	jwksTTL = 6 * time.Hour
)

// Identity is the verified result of a provider identity token.
type Identity struct {
	Provider string // "apple" | "google"
	Subject  string // stable provider subject (the JWT "sub")
	Email    string // display-only, may be empty
}

// ProviderVerifier verifies a single provider's identity tokens against its
// JWKS, enforcing signature, issuer, audience and expiry. `audiences` is a set
// of accepted `aud` values — a token verifies if its audience matches ANY of
// them, which lets Google sign-in cut over to a new OAuth client id without a
// window where the old and new clients can't both verify.
type ProviderVerifier struct {
	provider  string
	jwks      *jwksCache
	audiences []string
	issuers   []string
	now       func() time.Time
}

// NewAppleVerifier builds a verifier for Apple identity tokens.
func NewAppleVerifier(aud, iss string, client *http.Client) *ProviderVerifier {
	return &ProviderVerifier{
		provider:  "apple",
		jwks:      newJWKSCache(AppleJWKSURL, client, jwksTTL),
		audiences: []string{aud},
		issuers:   []string{iss},
		now:       time.Now,
	}
}

// NewGoogleVerifier builds a verifier for Google id_tokens. `auds` is the set of
// accepted client ids (a comma-separated GOOGLE_AUD splits into this), so a
// token from any configured client verifies — used for a zero-downtime client
// cutover.
func NewGoogleVerifier(auds []string, issuers []string, client *http.Client) *ProviderVerifier {
	return &ProviderVerifier{
		provider:  "google",
		jwks:      newJWKSCache(GoogleJWKSURL, client, jwksTTL),
		audiences: auds,
		issuers:   issuers,
		now:       time.Now,
	}
}

// NewAppleVerifierWithJWKS builds an Apple verifier pointed at an arbitrary
// JWKS endpoint. It exists so callers outside this package (and the OAuth
// code-exchange flow in tests) can verify Apple id_tokens against a mocked JWKS
// server. In production, prefer NewAppleVerifier.
func NewAppleVerifierWithJWKS(jwksURL, aud, iss string, client *http.Client) *ProviderVerifier {
	return newVerifierWithJWKSURL("apple", jwksURL, []string{aud}, []string{iss}, client)
}

// newVerifierWithJWKSURL is the test seam: it builds a verifier pointed at an
// arbitrary JWKS endpoint (a httptest server serving a fake JWKS).
func newVerifierWithJWKSURL(provider, jwksURL string, auds []string, issuers []string, client *http.Client) *ProviderVerifier {
	return &ProviderVerifier{
		provider:  provider,
		jwks:      newJWKSCache(jwksURL, client, jwksTTL),
		audiences: auds,
		issuers:   issuers,
		now:       time.Now,
	}
}

// Verify validates rawToken and returns the verified Identity. It checks RS256
// signature against the provider JWKS, plus aud, iss and exp.
func (v *ProviderVerifier) Verify(ctx context.Context, rawToken string) (Identity, error) {
	keyFunc := func(t *jwt.Token) (any, error) {
		if t.Method.Alg() != jwt.SigningMethodRS256.Alg() {
			return nil, fmt.Errorf("auth: unexpected signing method %q", t.Method.Alg())
		}
		kid, _ := t.Header["kid"].(string)
		if kid == "" {
			return nil, errors.New("auth: token missing kid")
		}
		return v.jwks.key(ctx, kid)
	}

	// Audience is checked manually (checkAudience) rather than via
	// jwt.WithAudience, which only accepts a single value — we accept any of a
	// configured set so a Google client-id cutover has no downtime.
	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{"RS256"}),
		jwt.WithExpirationRequired(),
		jwt.WithTimeFunc(v.now),
	)

	var claims jwt.MapClaims
	token, err := parser.ParseWithClaims(rawToken, &claims, keyFunc)
	if err != nil {
		return Identity{}, fmt.Errorf("auth: verify %s token: %w", v.provider, err)
	}
	if !token.Valid {
		return Identity{}, fmt.Errorf("auth: %s token invalid", v.provider)
	}

	if err := v.checkAudience(claims); err != nil {
		return Identity{}, err
	}
	if err := v.checkIssuer(claims); err != nil {
		return Identity{}, err
	}

	sub, _ := claims["sub"].(string)
	if sub == "" {
		return Identity{}, errors.New("auth: token missing sub")
	}
	email, _ := claims["email"].(string)

	return Identity{Provider: v.provider, Subject: sub, Email: email}, nil
}

func (v *ProviderVerifier) checkIssuer(claims jwt.MapClaims) error {
	iss, _ := claims["iss"].(string)
	for _, want := range v.issuers {
		if iss == want {
			return nil
		}
	}
	return fmt.Errorf("auth: %s token has unexpected iss %q", v.provider, iss)
}

// checkAudience verifies the token's `aud` claim matches any configured
// audience. The claim may be a string or an array (jwt.GetAudience normalizes
// both); a token verifies if any of its audiences is in the accepted set.
func (v *ProviderVerifier) checkAudience(claims jwt.MapClaims) error {
	auds, err := claims.GetAudience()
	if err != nil {
		return fmt.Errorf("auth: %s token has invalid aud: %w", v.provider, err)
	}
	for _, got := range auds {
		for _, want := range v.audiences {
			if got == want {
				return nil
			}
		}
	}
	return fmt.Errorf("auth: %s token aud %v not in accepted audiences", v.provider, []string(auds))
}
