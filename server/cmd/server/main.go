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
	apple := auth.NewAppleVerifier(cfg.AppleAud, cfg.AppleIss, httpClient)
	google := auth.NewGoogleVerifier(cfg.GoogleAud, config.GoogleIssuers, httpClient)

	srv := api.NewServer(repo, sessions, apple, google)

	httpServer := &http.Server{
		Addr:              net.JoinHostPort("127.0.0.1", cfg.Port),
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
