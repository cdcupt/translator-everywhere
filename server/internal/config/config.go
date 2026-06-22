// Package config loads runtime configuration from the environment only. No
// secrets are ever hardcoded; the public OAuth audiences default to the
// CONFIG.md values but remain env-overridable.
package config

import (
	"errors"
	"os"
)

// Defaults for the public (non-secret) identifiers, taken from
// docs/pipeline/macos-app/CONFIG.md. Overridable via env for staging/testing.
const (
	DefaultAppleAud  = "com.cdcupt.translator-everywhere"
	DefaultAppleIss  = "https://appleid.apple.com"
	DefaultGoogleAud = "328818408791-641sqb2v2smjgjud26e87j7rhnfo0uem.apps.googleusercontent.com"
	DefaultPort      = "8110"
	// DefaultBindAddr binds all interfaces inside the container. This is NOT a
	// public exposure: the container is published only on the host's
	// 127.0.0.1:8110, so 0.0.0.0 here is reachable solely from the host loopback.
	DefaultBindAddr = "0.0.0.0"
)

// GoogleIssuers are the two issuer strings Google's id_tokens use.
var GoogleIssuers = []string{"https://accounts.google.com", "accounts.google.com"}

// Config is the fully-resolved runtime configuration.
type Config struct {
	DatabaseURL string
	JWTSecret   string
	AppleAud    string
	AppleIss    string
	GoogleAud   string
	Port        string
	BindAddr    string
}

// Load reads configuration from the environment. DATABASE_URL and JWT_SECRET
// are required; the audiences default to the public CONFIG values.
func Load() (Config, error) {
	c := Config{
		DatabaseURL: os.Getenv("DATABASE_URL"),
		JWTSecret:   os.Getenv("JWT_SECRET"),
		AppleAud:    envOr("APPLE_AUD", DefaultAppleAud),
		AppleIss:    envOr("APPLE_ISS", DefaultAppleIss),
		GoogleAud:   envOr("GOOGLE_AUD", DefaultGoogleAud),
		Port:        envOr("PORT", DefaultPort),
		BindAddr:    envOr("BIND_ADDR", DefaultBindAddr),
	}
	if c.DatabaseURL == "" {
		return Config{}, errors.New("DATABASE_URL is required")
	}
	if c.JWTSecret == "" {
		return Config{}, errors.New("JWT_SECRET is required")
	}
	return c, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
