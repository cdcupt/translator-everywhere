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

	// Sign in with Apple (web OAuth flow) defaults. The Services ID is a public
	// identifier — the placeholder below is overridden by APPLE_SERVICES_ID once
	// the real Services ID is provisioned. The team id and redirect uri are the
	// known-good values from the Apple Developer account / Caddy config.
	DefaultAppleServicesID  = "com.cdcupt.translator-everywhere.web"
	DefaultAppleTeamID      = "NK3U2C365Z"
	DefaultAppleRedirectURI = "https://api.translator.daichenlab.com/auth/apple/callback"
	// DefaultAppCallbackScheme is the iOS/macOS custom URL scheme the backend
	// 302-redirects back to so ASWebAuthenticationSession can capture the result.
	DefaultAppCallbackScheme = "translator-everywhere"
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

	// Sign in with Apple — web OAuth flow.
	AppleServicesID   string // OAuth client_id; also the id_token audience.
	AppleKeyID        string // .p8 key id (header kid for the client_secret).
	AppleTeamID       string // client_secret iss.
	ApplePrivateKey   string // PEM contents of the .p8 EC private key (a SECRET).
	AppleRedirectURI  string // must match the URI registered on the Services ID.
	AppCallbackScheme string // custom URL scheme the backend redirects back to.
}

// AppleWebConfigured reports whether the secrets needed to run the Apple web
// OAuth code exchange are present. When false, /auth/apple/callback returns an
// error redirect rather than 500ing, and the rest of the API still serves.
func (c Config) AppleWebConfigured() bool {
	return c.AppleServicesID != "" && c.AppleKeyID != "" &&
		c.AppleTeamID != "" && c.ApplePrivateKey != ""
}

// Load reads configuration from the environment. DATABASE_URL and JWT_SECRET
// are required; the audiences default to the public CONFIG values. The Apple
// web-flow secrets are optional at boot — when absent, the Apple callback
// degrades to an error redirect rather than preventing startup.
func Load() (Config, error) {
	applePrivateKey, err := loadApplePrivateKey()
	if err != nil {
		return Config{}, err
	}

	c := Config{
		DatabaseURL: os.Getenv("DATABASE_URL"),
		JWTSecret:   os.Getenv("JWT_SECRET"),
		AppleAud:    envOr("APPLE_AUD", DefaultAppleAud),
		AppleIss:    envOr("APPLE_ISS", DefaultAppleIss),
		GoogleAud:   envOr("GOOGLE_AUD", DefaultGoogleAud),
		Port:        envOr("PORT", DefaultPort),
		BindAddr:    envOr("BIND_ADDR", DefaultBindAddr),

		AppleServicesID:   envOr("APPLE_SERVICES_ID", DefaultAppleServicesID),
		AppleKeyID:        os.Getenv("APPLE_KEY_ID"),
		AppleTeamID:       envOr("APPLE_TEAM_ID", DefaultAppleTeamID),
		ApplePrivateKey:   applePrivateKey,
		AppleRedirectURI:  envOr("APPLE_REDIRECT_URI", DefaultAppleRedirectURI),
		AppCallbackScheme: envOr("APP_CALLBACK_SCHEME", DefaultAppCallbackScheme),
	}
	if c.DatabaseURL == "" {
		return Config{}, errors.New("DATABASE_URL is required")
	}
	if c.JWTSecret == "" {
		return Config{}, errors.New("JWT_SECRET is required")
	}
	return c, nil
}

// loadApplePrivateKey returns the .p8 PEM contents from APPLE_PRIVATE_KEY (the
// PEM inline) or, failing that, the file named by APPLE_PRIVATE_KEY_FILE.
// Returns "" (not an error) when neither is set — Apple web auth is optional.
func loadApplePrivateKey() (string, error) {
	if inline := os.Getenv("APPLE_PRIVATE_KEY"); inline != "" {
		return inline, nil
	}
	if path := os.Getenv("APPLE_PRIVATE_KEY_FILE"); path != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			return "", errors.New("could not read APPLE_PRIVATE_KEY_FILE: " + err.Error())
		}
		return string(data), nil
	}
	return "", nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
