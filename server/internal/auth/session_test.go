package auth

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestSessionIssueVerifyRoundTrip(t *testing.T) {
	m := NewSessionManager("test-secret")
	userID := uuid.New()

	token, err := m.IssueAccessToken(userID)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	got, err := m.VerifyAccessToken(token)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if got != userID {
		t.Errorf("user id = %v, want %v", got, userID)
	}
}

func TestSessionExpiredRejected(t *testing.T) {
	base := time.Now()
	m := NewSessionManager("test-secret")
	m.now = func() time.Time { return base }

	token, err := m.IssueAccessToken(uuid.New())
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	// Advance clock past the access TTL.
	m.now = func() time.Time { return base.Add(AccessTTL + time.Minute) }
	if _, err := m.VerifyAccessToken(token); err == nil {
		t.Fatal("expected expired token to be rejected")
	}
}

func TestSessionWrongSecretRejected(t *testing.T) {
	issuer := NewSessionManager("secret-a")
	token, err := issuer.IssueAccessToken(uuid.New())
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	verifier := NewSessionManager("secret-b")
	if _, err := verifier.VerifyAccessToken(token); err == nil {
		t.Fatal("expected token signed with a different secret to be rejected")
	}
}

func TestRefreshTokenHashIsStable(t *testing.T) {
	m := NewSessionManager("test-secret")
	raw, expiresAt, err := m.NewRefreshToken()
	if err != nil {
		t.Fatalf("new refresh: %v", err)
	}
	if raw == "" {
		t.Fatal("expected a non-empty refresh token")
	}
	if !expiresAt.After(time.Now()) {
		t.Fatal("expected a future expiry")
	}
	if HashRefreshToken(raw) != HashRefreshToken(raw) {
		t.Fatal("hash should be deterministic")
	}
	if HashRefreshToken(raw) == raw {
		t.Fatal("stored hash must differ from the raw token")
	}
}
