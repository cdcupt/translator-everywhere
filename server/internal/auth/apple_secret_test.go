package auth

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// newTestECKey generates a throwaway P-256 key and its PKCS#8 PEM (the .p8
// shape Apple ships).
func newTestECKey(t *testing.T) (*ecdsa.PrivateKey, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate EC key: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal pkcs8: %v", err)
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	return key, pemBytes
}

func TestAppleClientSecretShape(t *testing.T) {
	key, _ := newTestECKey(t)

	const (
		teamID     = "NK3U2C365Z"
		keyID      = "ABC123KEYID"
		servicesID = "com.cdcupt.translator-everywhere.web"
	)

	fixedNow := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
	secret, err := NewAppleClientSecret(AppleSecretConfig{
		TeamID:     teamID,
		KeyID:      keyID,
		ServicesID: servicesID,
		PrivateKey: key,
	})
	if err != nil {
		t.Fatalf("new client secret: %v", err)
	}
	secret.now = func() time.Time { return fixedNow }

	tokenStr, err := secret.Generate()
	if err != nil {
		t.Fatalf("generate: %v", err)
	}

	// Parse + verify with the public key, asserting ES256.
	var claims jwt.RegisteredClaims
	parsed, err := jwt.NewParser(jwt.WithValidMethods([]string{"ES256"})).
		ParseWithClaims(tokenStr, &claims, func(tok *jwt.Token) (any, error) {
			return &key.PublicKey, nil
		})
	if err != nil {
		t.Fatalf("parse/verify client_secret: %v", err)
	}
	if !parsed.Valid {
		t.Fatal("client_secret not valid")
	}

	// Header: alg ES256 + kid.
	if alg, _ := parsed.Header["alg"].(string); alg != "ES256" {
		t.Errorf("header alg = %q, want ES256", alg)
	}
	if kid, _ := parsed.Header["kid"].(string); kid != keyID {
		t.Errorf("header kid = %q, want %q", kid, keyID)
	}

	// Claims: iss=team, sub=servicesID, aud=appleid.apple.com.
	if claims.Issuer != teamID {
		t.Errorf("iss = %q, want %q", claims.Issuer, teamID)
	}
	if claims.Subject != servicesID {
		t.Errorf("sub = %q, want %q", claims.Subject, servicesID)
	}
	if len(claims.Audience) != 1 || claims.Audience[0] != "https://appleid.apple.com" {
		t.Errorf("aud = %v, want [https://appleid.apple.com]", claims.Audience)
	}

	// iat == now; exp in the future but strictly < 6 months from iat.
	if claims.IssuedAt == nil || !claims.IssuedAt.Time.Equal(fixedNow) {
		t.Errorf("iat = %v, want %v", claims.IssuedAt, fixedNow)
	}
	if claims.ExpiresAt == nil {
		t.Fatal("missing exp")
	}
	lifetime := claims.ExpiresAt.Sub(fixedNow)
	if lifetime <= 0 {
		t.Errorf("exp must be in the future, lifetime = %v", lifetime)
	}
	sixMonths := 180 * 24 * time.Hour
	if lifetime >= sixMonths {
		t.Errorf("exp lifetime = %v, must be < 6 months (%v)", lifetime, sixMonths)
	}
}

func TestNewAppleClientSecretRequiresFields(t *testing.T) {
	key, _ := newTestECKey(t)
	full := AppleSecretConfig{TeamID: "T", KeyID: "K", ServicesID: "S", PrivateKey: key}

	cases := map[string]AppleSecretConfig{
		"missing team":     {KeyID: "K", ServicesID: "S", PrivateKey: key},
		"missing key id":   {TeamID: "T", ServicesID: "S", PrivateKey: key},
		"missing services": {TeamID: "T", KeyID: "K", PrivateKey: key},
		"missing key":      {TeamID: "T", KeyID: "K", ServicesID: "S"},
	}
	for name, cfg := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := NewAppleClientSecret(cfg); err == nil {
				t.Fatalf("expected error for %s", name)
			}
		})
	}
	if _, err := NewAppleClientSecret(full); err != nil {
		t.Fatalf("full config should succeed: %v", err)
	}
}

func TestParseApplePrivateKey(t *testing.T) {
	key, pemBytes := newTestECKey(t)

	parsed, err := ParseApplePrivateKey(pemBytes)
	if err != nil {
		t.Fatalf("parse pkcs8 p8: %v", err)
	}
	if parsed.D.Cmp(key.D) != 0 {
		t.Error("parsed key does not match original")
	}

	// SEC1 ("EC PRIVATE KEY") encoding is also accepted.
	der, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatalf("marshal sec1: %v", err)
	}
	sec1 := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der})
	if _, err := ParseApplePrivateKey(sec1); err != nil {
		t.Fatalf("parse sec1: %v", err)
	}

	// Garbage PEM is rejected.
	if _, err := ParseApplePrivateKey([]byte("not a pem")); err == nil {
		t.Fatal("expected error for non-PEM input")
	}
}
