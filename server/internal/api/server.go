// Package api wires the HTTP surface: chi router, auth middleware and the
// handlers for the auth + vocab sync endpoints. Handlers depend only on the
// db.Repository interface and the auth verifiers, which keeps them fakeable in
// tests with no Postgres.
package api

import (
	"context"
	"log"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/httprate"

	"github.com/cdcupt/translator-everywhere/server/internal/auth"
	"github.com/cdcupt/translator-everywhere/server/internal/db"
	"github.com/cdcupt/translator-everywhere/server/internal/secrets"
)

// IdentityVerifier verifies a provider identity token. ProviderVerifier
// satisfies this; tests can substitute a fake.
type IdentityVerifier interface {
	Verify(ctx context.Context, rawToken string) (auth.Identity, error)
}

// AppleCodeExchanger trades a Sign-in-with-Apple authorization code for a
// verified Identity. *auth.AppleOAuth satisfies this; tests substitute a fake.
type AppleCodeExchanger interface {
	ExchangeCode(ctx context.Context, code string) (auth.Identity, error)
}

// GoogleCodeExchanger trades a Google Desktop-loopback authorization code (with
// its PKCE verifier + redirect_uri) for a verified Identity. *auth.GoogleOAuth
// satisfies this; tests substitute a fake.
type GoogleCodeExchanger interface {
	ExchangeCode(ctx context.Context, code, codeVerifier, redirectURI string) (auth.Identity, error)
}

// Server holds the handler dependencies.
type Server struct {
	Repo     db.Repository
	Sessions *auth.SessionManager
	Google   IdentityVerifier

	// AppleOAuth runs the Sign in with Apple web-flow code exchange. It may be
	// nil when the Apple web secrets are not configured; the callback then
	// returns an error redirect instead of 500ing.
	AppleOAuth AppleCodeExchanger
	// GoogleOAuth runs the Google Desktop-loopback code exchange (server-side, so
	// the client_secret never ships in the app). nil when GOOGLE_CLIENT_SECRET is
	// absent; /auth/google then only accepts the legacy id_token body.
	GoogleOAuth GoogleCodeExchanger
	// AppCallbackScheme is the custom URL scheme the Apple callback 302s back to.
	AppCallbackScheme string

	// MaxBatch caps the number of rows accepted by POST /vocab.
	MaxBatch int

	// Sealer encrypts/decrypts user secrets for the /secret/* endpoints. It may
	// be nil when SECRET_ENCRYPTION_KEY is absent/invalid (T1 graceful-degrade):
	// the server still boots and only /secret/* returns 503.
	Sealer *secrets.Sealer

	// Logger receives handler-side error logs (user_id only — never the key or
	// blob). nil falls back to the standard logger; tests point it at a buffer to
	// assert no plaintext ever leaks.
	Logger *log.Logger
}

// secretRateLimit is the per-user request cap on /secret/* (T2 hardening).
const (
	secretRateLimit  = 30
	secretRateWindow = time.Minute
)

// logger returns the configured logger or the process default.
func (s *Server) logger() *log.Logger {
	if s.Logger != nil {
		return s.Logger
	}
	return log.Default()
}

// MaxBatchDefault is the default batch-size cap for POST /vocab.
const MaxBatchDefault = 500

// DefaultAppCallbackScheme matches config.DefaultAppCallbackScheme; duplicated
// here to avoid an api→config import just for one constant.
const DefaultAppCallbackScheme = "translator-everywhere"

// NewServer builds a Server with sensible defaults applied. appleOAuth may be
// nil when Apple web auth is not configured.
func NewServer(repo db.Repository, sessions *auth.SessionManager, appleOAuth AppleCodeExchanger, google IdentityVerifier) *Server {
	return &Server{
		Repo:              repo,
		Sessions:          sessions,
		AppleOAuth:        appleOAuth,
		Google:            google,
		AppCallbackScheme: DefaultAppCallbackScheme,
		MaxBatch:          MaxBatchDefault,
	}
}

// Router returns the fully-wired chi router.
func (s *Server) Router() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Recoverer)

	r.Get("/healthz", s.handleHealthz)

	// Sign in with Apple — WEB OAuth flow. Apple posts (form_post) or redirects
	// (query) the authorization code here; we exchange it and 302 back to the
	// app's custom scheme. Both verbs are registered because Apple uses form_post
	// when name/email scope is requested and a GET redirect otherwise.
	r.Get("/auth/apple/callback", s.handleAppleCallback)
	r.Post("/auth/apple/callback", s.handleAppleCallback)

	r.Post("/auth/google", s.handleGoogleSignIn)
	r.Post("/auth/refresh", s.handleRefresh)

	// Authenticated surface.
	r.Group(func(r chi.Router) {
		r.Use(s.authMiddleware)
		r.Post("/auth/signout", s.handleSignOut)
		r.Get("/vocab", s.handleVocabPull)
		r.Post("/vocab", s.handleVocabPush)
		r.Delete("/account", s.handleDeleteAccount)

		// Encrypted key-sync endpoints. Rate limit is per-user (keyed on the JWT
		// subject) and scoped to this subgroup only.
		r.Group(func(r chi.Router) {
			r.Use(httprate.Limit(
				secretRateLimit, secretRateWindow,
				httprate.WithKeyFuncs(secretRateKey),
			))
			r.Put("/secret/openai-key", s.handlePutSecret)
			r.Get("/secret/openai-key", s.handleGetSecret)
			r.Delete("/secret/openai-key", s.handleDeleteSecret)
		})
	})

	return r
}
