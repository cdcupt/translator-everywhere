// Package api wires the HTTP surface: chi router, auth middleware and the
// handlers for the auth + vocab sync endpoints. Handlers depend only on the
// db.Repository interface and the auth verifiers, which keeps them fakeable in
// tests with no Postgres.
package api

import (
	"context"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"github.com/cdcupt/translator-everywhere/server/internal/auth"
	"github.com/cdcupt/translator-everywhere/server/internal/db"
)

// IdentityVerifier verifies a provider identity token. ProviderVerifier
// satisfies this; tests can substitute a fake.
type IdentityVerifier interface {
	Verify(ctx context.Context, rawToken string) (auth.Identity, error)
}

// Server holds the handler dependencies.
type Server struct {
	Repo     db.Repository
	Sessions *auth.SessionManager
	Apple    IdentityVerifier
	Google   IdentityVerifier

	// MaxBatch caps the number of rows accepted by POST /vocab.
	MaxBatch int
}

// MaxBatchDefault is the default batch-size cap for POST /vocab.
const MaxBatchDefault = 500

// NewServer builds a Server with sensible defaults applied.
func NewServer(repo db.Repository, sessions *auth.SessionManager, apple, google IdentityVerifier) *Server {
	return &Server{
		Repo:     repo,
		Sessions: sessions,
		Apple:    apple,
		Google:   google,
		MaxBatch: MaxBatchDefault,
	}
}

// Router returns the fully-wired chi router.
func (s *Server) Router() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Recoverer)

	r.Get("/healthz", s.handleHealthz)

	r.Post("/auth/apple", s.handleAppleSignIn)
	r.Post("/auth/google", s.handleGoogleSignIn)
	r.Post("/auth/refresh", s.handleRefresh)

	// Authenticated surface.
	r.Group(func(r chi.Router) {
		r.Use(s.authMiddleware)
		r.Post("/auth/signout", s.handleSignOut)
		r.Get("/vocab", s.handleVocabPull)
		r.Post("/vocab", s.handleVocabPush)
		r.Delete("/account", s.handleDeleteAccount)
	})

	return r
}
