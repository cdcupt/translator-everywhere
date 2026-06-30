// Command server is the Translator Everywhere auth + vocab sync API. On boot it
// runs goose migrations, then serves the chi router defined in internal/api.
package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net"
	"net/http"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	"github.com/cdcupt/translator-everywhere/server/internal/api"
	"github.com/cdcupt/translator-everywhere/server/internal/auth"
	"github.com/cdcupt/translator-everywhere/server/internal/config"
	"github.com/cdcupt/translator-everywhere/server/internal/db"
	"github.com/cdcupt/translator-everywhere/server/migrations"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("server: %v", err)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	if err := runMigrations(cfg.DatabaseURL); err != nil {
		return err
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	repo := db.NewPostgresRepository(pool)
	sessions := auth.NewSessionManager(cfg.JWTSecret)
	httpClient := &http.Client{Timeout: 10 * time.Second}
	google := auth.NewGoogleVerifier(cfg.GoogleAuds(), config.GoogleIssuers, httpClient)

	appleOAuth, err := buildAppleOAuth(cfg, httpClient)
	if err != nil {
		return err
	}

	srv := api.NewServer(repo, sessions, appleOAuth, google)
	srv.AppCallbackScheme = cfg.AppCallbackScheme

	httpServer := &http.Server{
		Addr:              net.JoinHostPort(cfg.BindAddr, cfg.Port),
		Handler:           srv.Router(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shutdownCancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	log.Printf("server: listening on %s", httpServer.Addr)
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// buildAppleOAuth wires the Sign in with Apple web-flow exchanger from config.
// When the Apple web secrets are absent it returns (nil, nil): the server still
// boots and /auth/apple/callback degrades to an error redirect. A present-but-
// malformed private key is a hard error so misconfiguration fails fast.
func buildAppleOAuth(cfg config.Config, client *http.Client) (*auth.AppleOAuth, error) {
	if !cfg.AppleWebConfigured() {
		log.Printf("server: Sign in with Apple (web) not configured — /auth/apple/callback will error-redirect")
		return nil, nil
	}

	privKey, err := auth.ParseApplePrivateKey([]byte(cfg.ApplePrivateKey))
	if err != nil {
		return nil, err
	}
	secret, err := auth.NewAppleClientSecret(auth.AppleSecretConfig{
		TeamID:     cfg.AppleTeamID,
		KeyID:      cfg.AppleKeyID,
		ServicesID: cfg.AppleServicesID,
		PrivateKey: privKey,
	})
	if err != nil {
		return nil, err
	}

	// The web-flow id_token audience is the Services ID (the OAuth client_id).
	verifier := auth.NewAppleVerifier(cfg.AppleServicesID, cfg.AppleIss, client)

	return auth.NewAppleOAuth(auth.AppleOAuthConfig{
		ServicesID:  cfg.AppleServicesID,
		RedirectURI: cfg.AppleRedirectURI,
		Secret:      secret,
		Verifier:    verifier,
		HTTPClient:  client,
	})
}

// runMigrations applies the embedded goose migrations against the database.
func runMigrations(databaseURL string) error {
	sqlDB, err := sql.Open("pgx", databaseURL)
	if err != nil {
		return err
	}
	defer sqlDB.Close()

	goose.SetBaseFS(migrations.FS)
	if err := goose.SetDialect("postgres"); err != nil {
		return err
	}
	if err := goose.Up(sqlDB, "."); err != nil {
		return err
	}
	return nil
}
