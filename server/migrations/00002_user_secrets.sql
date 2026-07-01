-- +goose Up
-- +goose StatementBegin
-- user_secrets holds at most one encrypted secret row per (user, slot). The
-- handler hardcodes name='openai-key'; the column is left unconstrained (YAGNI)
-- so future slots need no schema change. blob is the opaque AES-256-GCM envelope
-- (key_id || nonce || ciphertext+tag) — ciphertext only, never plaintext. The
-- row cascades away when the owning user is deleted.
CREATE TABLE IF NOT EXISTS user_secrets (
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name       text        NOT NULL,
    blob       bytea       NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT user_secrets_pkey PRIMARY KEY (user_id, name)
);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS user_secrets;
-- +goose StatementEnd
