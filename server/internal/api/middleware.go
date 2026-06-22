package api

import (
	"context"
	"net/http"
	"strings"

	"github.com/google/uuid"
)

type ctxKey string

const userIDKey ctxKey = "userID"

// authMiddleware authenticates a request via the Authorization: Bearer
// <session-jwt> header and stashes the verified user id in the context. A
// missing or blank token is rejected with 401.
func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw := bearerToken(r)
		if raw == "" {
			writeError(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		userID, err := s.Sessions.VerifyAccessToken(raw)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "invalid or expired token")
			return
		}
		ctx := context.WithValue(r.Context(), userIDKey, userID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// bearerToken extracts the token from a "Bearer <token>" Authorization header.
func bearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(h) <= len(prefix) || !strings.EqualFold(h[:len(prefix)], prefix) {
		return ""
	}
	return strings.TrimSpace(h[len(prefix):])
}

// userIDFromContext returns the authenticated user id set by authMiddleware.
func userIDFromContext(ctx context.Context) (uuid.UUID, bool) {
	id, ok := ctx.Value(userIDKey).(uuid.UUID)
	return id, ok
}
