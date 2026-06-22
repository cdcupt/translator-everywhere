package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

// Session token lifetimes (TECH §3): short access JWT, long refresh token.
const (
	AccessTTL  = time.Hour
	RefreshTTL = 60 * 24 * time.Hour // 60 days
)

const sessionIssuer = "translator-everywhere"

// SessionManager issues and verifies our own session JWTs (HS256) and mints
// opaque refresh tokens. The signing secret comes from config (env only).
type SessionManager struct {
	secret []byte
	now    func() time.Time
}

// NewSessionManager builds a manager from the server signing secret.
func NewSessionManager(secret string) *SessionManager {
	return &SessionManager{secret: []byte(secret), now: time.Now}
}

// IssueAccessToken returns a signed access JWT whose subject is the user id.
func (m *SessionManager) IssueAccessToken(userID uuid.UUID) (string, error) {
	now := m.now()
	claims := jwt.RegisteredClaims{
		Subject:   userID.String(),
		Issuer:    sessionIssuer,
		IssuedAt:  jwt.NewNumericDate(now),
		ExpiresAt: jwt.NewNumericDate(now.Add(AccessTTL)),
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := tok.SignedString(m.secret)
	if err != nil {
		return "", fmt.Errorf("auth: sign access token: %w", err)
	}
	return signed, nil
}

// VerifyAccessToken validates a session JWT and returns its user id.
func (m *SessionManager) VerifyAccessToken(raw string) (uuid.UUID, error) {
	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{"HS256"}),
		jwt.WithIssuer(sessionIssuer),
		jwt.WithExpirationRequired(),
		jwt.WithTimeFunc(m.now),
	)
	var claims jwt.RegisteredClaims
	tok, err := parser.ParseWithClaims(raw, &claims, func(t *jwt.Token) (any, error) {
		return m.secret, nil
	})
	if err != nil {
		return uuid.Nil, fmt.Errorf("auth: verify access token: %w", err)
	}
	if !tok.Valid {
		return uuid.Nil, errors.New("auth: access token invalid")
	}
	id, err := uuid.Parse(claims.Subject)
	if err != nil {
		return uuid.Nil, fmt.Errorf("auth: bad subject: %w", err)
	}
	return id, nil
}

// NewRefreshToken returns a cryptographically-random opaque refresh token plus
// the expiry the caller should persist. Only HashRefreshToken(raw) is stored
// server-side.
func (m *SessionManager) NewRefreshToken() (raw string, expiresAt time.Time, err error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", time.Time{}, fmt.Errorf("auth: generate refresh token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(b), m.now().Add(RefreshTTL), nil
}

// HashRefreshToken returns the storage hash for a raw refresh token. The raw
// token is never persisted in cleartext.
func HashRefreshToken(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}
