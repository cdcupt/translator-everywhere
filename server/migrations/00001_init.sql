-- +goose Up
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS users (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider         text        NOT NULL,
    provider_subject text        NOT NULL,
    email            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT users_provider_subject_key UNIQUE (provider, provider_subject)
);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS vocab_items (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    client_uuid uuid        NOT NULL,
    source_text text        NOT NULL,
    translation text        NOT NULL,
    src_lang    text        NOT NULL,
    tgt_lang    text        NOT NULL,
    engine      text        NOT NULL,
    tag         text,
    deleted     boolean     NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT vocab_items_user_client_key UNIQUE (user_id, client_uuid)
);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS vocab_items_user_updated_idx
    ON vocab_items (user_id, updated_at);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS refresh_tokens (
    token_hash text        PRIMARY KEY,
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS refresh_tokens_user_idx
    ON refresh_tokens (user_id);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS refresh_tokens;
-- +goose StatementEnd
-- +goose StatementBegin
DROP TABLE IF EXISTS vocab_items;
-- +goose StatementEnd
-- +goose StatementBegin
DROP TABLE IF EXISTS users;
-- +goose StatementEnd
