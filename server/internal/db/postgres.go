package db

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// PostgresRepository is the pgx-backed Repository used in production.
type PostgresRepository struct {
	pool *pgxpool.Pool
}

// NewPostgresRepository wraps a pgx pool.
func NewPostgresRepository(pool *pgxpool.Pool) *PostgresRepository {
	return &PostgresRepository{pool: pool}
}

var _ Repository = (*PostgresRepository)(nil)

func (r *PostgresRepository) UpsertUser(ctx context.Context, p UpsertUserParams) (User, error) {
	const q = `
INSERT INTO users (provider, provider_subject, email)
VALUES ($1, $2, $3)
ON CONFLICT (provider, provider_subject)
DO UPDATE SET email = COALESCE(EXCLUDED.email, users.email)
RETURNING id, provider, provider_subject, email, created_at`
	var u User
	err := r.pool.QueryRow(ctx, q, p.Provider, p.ProviderSubject, p.Email).
		Scan(&u.ID, &u.Provider, &u.ProviderSubject, &u.Email, &u.CreatedAt)
	if err != nil {
		return User{}, err
	}
	return u, nil
}

func (r *PostgresRepository) GetUser(ctx context.Context, id uuid.UUID) (User, error) {
	const q = `
SELECT id, provider, provider_subject, email, created_at
FROM users WHERE id = $1`
	var u User
	err := r.pool.QueryRow(ctx, q, id).
		Scan(&u.ID, &u.Provider, &u.ProviderSubject, &u.Email, &u.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return User{}, ErrNotFound
	}
	if err != nil {
		return User{}, err
	}
	return u, nil
}

func (r *PostgresRepository) UpsertVocab(ctx context.Context, p UpsertVocabParams) (VocabItem, bool, error) {
	// created_at falls back to the incoming updated_at on first insert; the
	// WHERE guard makes the update a no-op when the stored row is newer.
	const q = `
INSERT INTO vocab_items (
    user_id, client_uuid, source_text, translation,
    src_lang, tgt_lang, engine, tag, deleted, created_at, updated_at
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $10)
ON CONFLICT (user_id, client_uuid) DO UPDATE SET
    source_text = EXCLUDED.source_text,
    translation = EXCLUDED.translation,
    src_lang    = EXCLUDED.src_lang,
    tgt_lang    = EXCLUDED.tgt_lang,
    engine      = EXCLUDED.engine,
    tag         = EXCLUDED.tag,
    deleted     = EXCLUDED.deleted,
    updated_at  = EXCLUDED.updated_at
WHERE EXCLUDED.updated_at > vocab_items.updated_at
RETURNING id, user_id, client_uuid, source_text, translation,
          src_lang, tgt_lang, engine, tag, deleted, created_at, updated_at`
	var it VocabItem
	err := r.pool.QueryRow(ctx, q,
		p.UserID, p.ClientUUID, p.SourceText, p.Translation,
		p.SrcLang, p.TgtLang, p.Engine, p.Tag, p.Deleted, p.UpdatedAt,
	).Scan(
		&it.ID, &it.UserID, &it.ClientUUID, &it.SourceText, &it.Translation,
		&it.SrcLang, &it.TgtLang, &it.Engine, &it.Tag, &it.Deleted,
		&it.CreatedAt, &it.UpdatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		// Conflict guard suppressed the write (stored row was newer); fetch the
		// authoritative current row so the caller can report a conflict.
		current, gErr := r.getVocab(ctx, p.UserID, p.ClientUUID)
		if gErr != nil {
			return VocabItem{}, false, gErr
		}
		return current, false, nil
	}
	if err != nil {
		return VocabItem{}, false, err
	}
	return it, true, nil
}

func (r *PostgresRepository) getVocab(ctx context.Context, userID, clientUUID uuid.UUID) (VocabItem, error) {
	const q = `
SELECT id, user_id, client_uuid, source_text, translation,
       src_lang, tgt_lang, engine, tag, deleted, created_at, updated_at
FROM vocab_items WHERE user_id = $1 AND client_uuid = $2`
	var it VocabItem
	err := r.pool.QueryRow(ctx, q, userID, clientUUID).Scan(
		&it.ID, &it.UserID, &it.ClientUUID, &it.SourceText, &it.Translation,
		&it.SrcLang, &it.TgtLang, &it.Engine, &it.Tag, &it.Deleted,
		&it.CreatedAt, &it.UpdatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return VocabItem{}, ErrNotFound
	}
	return it, err
}

func (r *PostgresRepository) ListVocabSince(ctx context.Context, userID uuid.UUID, since time.Time) ([]VocabItem, error) {
	const q = `
SELECT id, user_id, client_uuid, source_text, translation,
       src_lang, tgt_lang, engine, tag, deleted, created_at, updated_at
FROM vocab_items
WHERE user_id = $1 AND updated_at > $2
ORDER BY updated_at ASC`
	rows, err := r.pool.Query(ctx, q, userID, since)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	items := make([]VocabItem, 0)
	for rows.Next() {
		var it VocabItem
		if err := rows.Scan(
			&it.ID, &it.UserID, &it.ClientUUID, &it.SourceText, &it.Translation,
			&it.SrcLang, &it.TgtLang, &it.Engine, &it.Tag, &it.Deleted,
			&it.CreatedAt, &it.UpdatedAt,
		); err != nil {
			return nil, err
		}
		items = append(items, it)
	}
	return items, rows.Err()
}

func (r *PostgresRepository) DeleteAccount(ctx context.Context, userID uuid.UUID) error {
	_, err := r.pool.Exec(ctx, `DELETE FROM users WHERE id = $1`, userID)
	return err
}

func (r *PostgresRepository) InsertRefreshToken(ctx context.Context, t RefreshToken) error {
	_, err := r.pool.Exec(ctx,
		`INSERT INTO refresh_tokens (token_hash, user_id, expires_at) VALUES ($1, $2, $3)`,
		t.TokenHash, t.UserID, t.ExpiresAt)
	return err
}

func (r *PostgresRepository) GetRefreshToken(ctx context.Context, tokenHash string) (RefreshToken, error) {
	const q = `
SELECT token_hash, user_id, expires_at, created_at
FROM refresh_tokens WHERE token_hash = $1`
	var t RefreshToken
	err := r.pool.QueryRow(ctx, q, tokenHash).
		Scan(&t.TokenHash, &t.UserID, &t.ExpiresAt, &t.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return RefreshToken{}, ErrNotFound
	}
	if err != nil {
		return RefreshToken{}, err
	}
	return t, nil
}

func (r *PostgresRepository) DeleteRefreshToken(ctx context.Context, tokenHash string) error {
	_, err := r.pool.Exec(ctx, `DELETE FROM refresh_tokens WHERE token_hash = $1`, tokenHash)
	return err
}

func (r *PostgresRepository) UpsertSecret(ctx context.Context, p UpsertSecretParams) (UserSecret, error) {
	// LWW: the update only fires when the incoming updated_at is at least as new
	// as the stored one. On an older (stale) write the guard suppresses the
	// update, RETURNING yields no rows, and we fetch the authoritative current
	// row instead so the caller sees the winning value.
	const q = `
INSERT INTO user_secrets (user_id, name, blob, updated_at)
VALUES ($1, $2, $3, $4)
ON CONFLICT (user_id, name) DO UPDATE SET
    blob       = EXCLUDED.blob,
    updated_at = EXCLUDED.updated_at
WHERE EXCLUDED.updated_at >= user_secrets.updated_at
RETURNING user_id, name, blob, updated_at`
	var s UserSecret
	err := r.pool.QueryRow(ctx, q, p.UserID, p.Name, p.Blob, p.UpdatedAt).
		Scan(&s.UserID, &s.Name, &s.Blob, &s.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return r.GetSecret(ctx, p.UserID, p.Name)
	}
	if err != nil {
		return UserSecret{}, err
	}
	return s, nil
}

func (r *PostgresRepository) GetSecret(ctx context.Context, userID uuid.UUID, name string) (UserSecret, error) {
	const q = `
SELECT user_id, name, blob, updated_at
FROM user_secrets WHERE user_id = $1 AND name = $2`
	var s UserSecret
	err := r.pool.QueryRow(ctx, q, userID, name).
		Scan(&s.UserID, &s.Name, &s.Blob, &s.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return UserSecret{}, ErrNotFound
	}
	if err != nil {
		return UserSecret{}, err
	}
	return s, nil
}

func (r *PostgresRepository) DeleteSecret(ctx context.Context, userID uuid.UUID, name string) error {
	_, err := r.pool.Exec(ctx, `DELETE FROM user_secrets WHERE user_id = $1 AND name = $2`, userID, name)
	return err
}
