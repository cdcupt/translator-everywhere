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
// JWKS, enforcing signature, issuer, audience and expiry.
type ProviderVerifier struct {
	provider string
	jwks     *jwksCache
	audience string
	issuers  []string
	now      func() time.Time
}

// NewAppleVerifier builds a verifier for Apple identity tokens.
func NewAppleVerifier(aud, iss string, client *http.Client) *ProviderVerifier {
	return &ProviderVerifier{
		provider: "apple",
		jwks:     newJWKSCache(AppleJWKSURL, client, jwksTTL),
		audience: aud,
		issuers:  []string{iss},
		now:      time.Now,
	}
}

// NewGoogleVerifier builds a verifier for Google id_tokens.
func NewGoogleVerifier(aud string, issuers []string, client *http.Client) *ProviderVerifier {
	return &ProviderVerifier{
		provider: "google",
		jwks:     newJWKSCache(GoogleJWKSURL, client, jwksTTL),
		audience: aud,
		issuers:  issuers,
		now:      time.Now,
	}
}

// newVerifierWithJWKSURL is the test seam: it builds a verifier pointed at an
// arbitrary JWKS endpoint (a httptest server serving a fake JWKS).
func newVerifierWithJWKSURL(provider, jwksURL, aud string, issuers []string, client *http.Client) *ProviderVerifier {
	return &ProviderVerifier{
		provider: provider,
		jwks:     newJWKSCache(jwksURL, client, jwksTTL),
		audience: aud,
		issuers:  issuers,
		now:      time.Now,
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

	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{"RS256"}),
		jwt.WithAudience(v.audience),
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
