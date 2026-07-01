package db

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
)

// ErrNotFound is returned by lookups that match no row.
var ErrNotFound = errors.New("not found")

// Repository is the storage boundary every handler depends on. The pgx
// implementation lives in postgres.go; tests use an in-memory fake.
type Repository interface {
	// UpsertUser creates or updates an account by (provider, provider_subject)
	// and returns the canonical row.
	UpsertUser(ctx context.Context, p UpsertUserParams) (User, error)

	// GetUser fetches a user by internal id. Returns ErrNotFound if absent.
	GetUser(ctx context.Context, id uuid.UUID) (User, error)

	// UpsertVocab applies one row with last-write-wins semantics: it only
	// overwrites an existing row when the incoming updated_at is strictly
	// newer. Returns (row, applied, error) where applied reports whether the
	// write changed/created the stored row.
	UpsertVocab(ctx context.Context, p UpsertVocabParams) (VocabItem, bool, error)

	// ListVocabSince returns every row (including tombstones) with
	// updated_at > since, ordered ascending by updated_at.
	ListVocabSince(ctx context.Context, userID uuid.UUID, since time.Time) ([]VocabItem, error)

	// DeleteAccount removes the user and (via cascade) all of their rows and
	// refresh tokens.
	DeleteAccount(ctx context.Context, userID uuid.UUID) error

	// InsertRefreshToken persists a hashed refresh-token record.
	InsertRefreshToken(ctx context.Context, t RefreshToken) error

	// GetRefreshToken looks up a refresh-token record by its hash. Returns
	// ErrNotFound if absent.
	GetRefreshToken(ctx context.Context, tokenHash string) (RefreshToken, error)

	// DeleteRefreshToken revokes a refresh token (best-effort signout).
	DeleteRefreshToken(ctx context.Context, tokenHash string) error

	// UpsertSecret writes an encrypted secret with last-write-wins semantics on
	// UpdatedAt: an incoming write only overwrites the stored row when its
	// UpdatedAt is >= the stored one, so a stale (older) write is ignored.
	// Returns the authoritative stored row.
	UpsertSecret(ctx context.Context, p UpsertSecretParams) (UserSecret, error)

	// GetSecret fetches the encrypted secret for (userID, name). Returns
	// ErrNotFound when the user has no such row.
	GetSecret(ctx context.Context, userID uuid.UUID, name string) (UserSecret, error)

	// DeleteSecret removes the secret for (userID, name). Idempotent — deleting a
	// missing row is not an error.
	DeleteSecret(ctx context.Context, userID uuid.UUID, name string) error
}
