package config

import (
	"os"
	"testing"
)

func TestLoadDefaultsAuds(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://localhost/test")
	t.Setenv("JWT_SECRET", "secret")
	// Ensure overrides are unset for this test.
	t.Setenv("APPLE_AUD", "")
	t.Setenv("GOOGLE_AUD", "")
	t.Setenv("PORT", "")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.AppleAud != DefaultAppleAud {
		t.Errorf("AppleAud = %q, want default %q", cfg.AppleAud, DefaultAppleAud)
	}
	if cfg.GoogleAud != DefaultGoogleAud {
		t.Errorf("GoogleAud = %q, want default %q", cfg.GoogleAud, DefaultGoogleAud)
	}
	if cfg.Port != DefaultPort {
		t.Errorf("Port = %q, want default %q", cfg.Port, DefaultPort)
	}
	if cfg.BindAddr != DefaultBindAddr {
		t.Errorf("BindAddr = %q, want default %q", cfg.BindAddr, DefaultBindAddr)
	}
}

func TestLoadBindAddrDefault(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://localhost/test")
	t.Setenv("JWT_SECRET", "secret")
	t.Setenv("BIND_ADDR", "")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.BindAddr != "0.0.0.0" {
		t.Errorf("BindAddr = %q, want %q", cfg.BindAddr, "0.0.0.0")
	}
}

func TestLoadBindAddrOverride(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://localhost/test")
	t.Setenv("JWT_SECRET", "secret")
	t.Setenv("BIND_ADDR", "127.0.0.1")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.BindAddr != "127.0.0.1" {
		t.Errorf("BindAddr override not applied: %q", cfg.BindAddr)
	}
}

func TestLoadOverrideAud(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://localhost/test")
	t.Setenv("JWT_SECRET", "secret")
	t.Setenv("GOOGLE_AUD", "override.apps.googleusercontent.com")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.GoogleAud != "override.apps.googleusercontent.com" {
		t.Errorf("GoogleAud override not applied: %q", cfg.GoogleAud)
	}
}

func TestLoadAppleWebDefaults(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://localhost/test")
	t.Setenv("JWT_SECRET", "secret")
	// Clear all Apple web overrides.
	t.Setenv("APPLE_SERVICES_ID", "")
	t.Setenv("APPLE_KEY_ID", "")
	t.Setenv("APPLE_TEAM_ID", "")
	t.Setenv("APPLE_PRIVATE_KEY", "")
	t.Setenv("APPLE_PRIVATE_KEY_FILE", "")
	t.Setenv("APPLE_REDIRECT_URI", "")
	t.Setenv("APP_CALLBACK_SCHEME", "")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.AppleServicesID != DefaultAppleServicesID {
		t.Errorf("AppleServicesID = %q, want default %q", cfg.AppleServicesID, DefaultAppleServicesID)
	}
	if cfg.AppleTeamID != DefaultAppleTeamID {
		t.Errorf("AppleTeamID = %q, want default %q", cfg.AppleTeamID, DefaultAppleTeamID)
	}
	if cfg.AppleRedirectURI != DefaultAppleRedirectURI {
		t.Errorf("AppleRedirectURI = %q, want default %q", cfg.AppleRedirectURI, DefaultAppleRedirectURI)
	}
	if cfg.AppCallbackScheme != DefaultAppCallbackScheme {
		t.Errorf("AppCallbackScheme = %q, want default %q", cfg.AppCallbackScheme, DefaultAppCallbackScheme)
	}
	// Without a key id + private key, Apple web is NOT considered configured.
	if cfg.AppleWebConfigured() {
		t.Error("AppleWebConfigured() should be false without key id + private key")
	}
}

func TestLoadAppleWebConfiguredAndKeyFromFile(t *testing.T) {
	dir := t.TempDir()
	keyPath := dir + "/AuthKey.p8"
	if err := os.WriteFile(keyPath, []byte("-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----\n"), 0o600); err != nil {
		t.Fatalf("write key file: %v", err)
	}

	t.Setenv("DATABASE_URL", "postgres://localhost/test")
	t.Setenv("JWT_SECRET", "secret")
	t.Setenv("APPLE_SERVICES_ID", "com.example.web")
	t.Setenv("APPLE_KEY_ID", "KEY123")
	t.Setenv("APPLE_TEAM_ID", "TEAM456")
	t.Setenv("APPLE_PRIVATE_KEY", "")
	t.Setenv("APPLE_PRIVATE_KEY_FILE", keyPath)

	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.AppleServicesID != "com.example.web" {
		t.Errorf("AppleServicesID override not applied: %q", cfg.AppleServicesID)
	}
	if cfg.AppleKeyID != "KEY123" {
		t.Errorf("AppleKeyID = %q", cfg.AppleKeyID)
	}
	if cfg.ApplePrivateKey == "" {
		t.Error("ApplePrivateKey should be loaded from APPLE_PRIVATE_KEY_FILE")
	}
	if !cfg.AppleWebConfigured() {
		t.Error("AppleWebConfigured() should be true with all fields present")
	}
}

func TestLoadAppleInlineKeyWins(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://localhost/test")
	t.Setenv("JWT_SECRET", "secret")
	t.Setenv("APPLE_PRIVATE_KEY", "INLINE-PEM")
	t.Setenv("APPLE_PRIVATE_KEY_FILE", "/nonexistent/should/not/be/read")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.ApplePrivateKey != "INLINE-PEM" {
		t.Errorf("inline key should win: %q", cfg.ApplePrivateKey)
	}
}

func TestLoadRequiresSecrets(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	t.Setenv("JWT_SECRET", "")
	if _, err := Load(); err == nil {
		t.Fatal("expected error when required env is missing")
	}

	t.Setenv("DATABASE_URL", "postgres://localhost/test")
	if _, err := Load(); err == nil {
		t.Fatal("expected error when JWT_SECRET is missing")
	}
}
