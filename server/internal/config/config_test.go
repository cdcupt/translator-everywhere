package config

import "testing"

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
