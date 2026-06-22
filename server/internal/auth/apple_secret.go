package auth

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// appleClientSecretTTL is the lifetime of a generated client_secret JWT. Apple
// requires exp < 6 months from iat; we use ~173 days (15_000_000 seconds) to
// stay comfortably under that ceiling while minimising regeneration churn.
const appleClientSecretTTL = 15_000_000 * time.Second

// appleTokenAudience is the fixed audience Apple expects in the client_secret.
const appleTokenAudience = "https://appleid.apple.com"

// AppleSecretConfig holds the static identifiers and signing key needed to mint
// the Apple OAuth client_secret JWT (signed ES256 per Apple's spec).
type AppleSecretConfig struct {
	TeamID     string            // APPLE_TEAM_ID → JWT iss
	KeyID      string            // APPLE_KEY_ID → JWT header kid
	ServicesID string            // APPLE_SERVICES_ID → JWT sub (also the OAuth client_id)
	PrivateKey *ecdsa.PrivateKey // EC P-256 key loaded from the .p8 PEM
}

// AppleClientSecret builds short-lived ES256 client_secret JWTs for Apple's
// OAuth token endpoint. The signing key is held in memory only; nothing is
// persisted.
type AppleClientSecret struct {
	cfg AppleSecretConfig
	now func() time.Time
}

// NewAppleClientSecret validates the config and returns a secret builder.
func NewAppleClientSecret(cfg AppleSecretConfig) (*AppleClientSecret, error) {
	if cfg.TeamID == "" {
		return nil, errors.New("auth: apple client_secret needs a team id")
	}
	if cfg.KeyID == "" {
		return nil, errors.New("auth: apple client_secret needs a key id")
	}
	if cfg.ServicesID == "" {
		return nil, errors.New("auth: apple client_secret needs a services id")
	}
	if cfg.PrivateKey == nil {
		return nil, errors.New("auth: apple client_secret needs a private key")
	}
	return &AppleClientSecret{cfg: cfg, now: time.Now}, nil
}

// Generate returns a freshly-signed client_secret JWT valid from now.
func (a *AppleClientSecret) Generate() (string, error) {
	now := a.now()
	claims := jwt.RegisteredClaims{
		Issuer:    a.cfg.TeamID,
		Subject:   a.cfg.ServicesID,
		Audience:  jwt.ClaimStrings{appleTokenAudience},
		IssuedAt:  jwt.NewNumericDate(now),
		ExpiresAt: jwt.NewNumericDate(now.Add(appleClientSecretTTL)),
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
	tok.Header["kid"] = a.cfg.KeyID

	signed, err := tok.SignedString(a.cfg.PrivateKey)
	if err != nil {
		return "", fmt.Errorf("auth: sign apple client_secret: %w", err)
	}
	return signed, nil
}

// ParseApplePrivateKey decodes an Apple .p8 PEM (PKCS#8, as downloaded from the
// Apple Developer portal) into an EC P-256 private key. It also tolerates a raw
// SEC1 "EC PRIVATE KEY" block for robustness.
func ParseApplePrivateKey(pemBytes []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("auth: apple private key is not valid PEM")
	}

	if key, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		ecKey, ok := key.(*ecdsa.PrivateKey)
		if !ok {
			return nil, errors.New("auth: apple private key is not an EC key")
		}
		return ecKey, nil
	}

	// Fall back to SEC1 for non-PKCS#8 encodings.
	ecKey, err := x509.ParseECPrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("auth: parse apple private key: %w", err)
	}
	return ecKey, nil
}
