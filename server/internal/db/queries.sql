-- name: UpsertUser :one
-- Upsert identity by (provider, provider_subject). Email is display-only and
-- refreshed on each sign-in when provided.
INSERT INTO users (provider, provider_subject, email)
VALUES ($1, $2, $3)
ON CONFLICT (provider, provider_subject)
DO UPDATE SET email = COALESCE(EXCLUDED.email, users.email)
RETURNING id, provider, provider_subject, email, created_at;

-- name: GetUser :one
SELECT id, provider, provider_subject, email, created_at
FROM users
WHERE id = $1;

-- name: UpsertVocabItem :one
-- Idempotent upsert keyed on (user_id, client_uuid). Last-write-wins: the
-- incoming row only overwrites when its updated_at is strictly newer.
INSERT INTO vocab_items (
    user_id, client_uuid, source_text, translation,
    src_lang, tgt_lang, engine, tag, deleted, created_at, updated_at
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
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
RETURNING *;

-- name: ListVocabSince :many
-- Pull half of sync: every row (including tombstones) changed since the cursor.
SELECT *
FROM vocab_items
WHERE user_id = $1 AND updated_at > $2
ORDER BY updated_at ASC;

-- name: DeleteAccount :exec
-- Cascades to vocab_items + refresh_tokens via ON DELETE CASCADE.
DELETE FROM users WHERE id = $1;

-- name: InsertRefreshToken :exec
INSERT INTO refresh_tokens (token_hash, user_id, expires_at)
VALUES ($1, $2, $3);

-- name: GetRefreshToken :one
SELECT token_hash, user_id, expires_at, created_at
FROM refresh_tokens
WHERE token_hash = $1;

-- name: DeleteRefreshToken :exec
DELETE FROM refresh_tokens WHERE token_hash = $1;
