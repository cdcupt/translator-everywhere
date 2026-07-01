// Package db defines the persistence boundary: domain models, the Repository
// interface handlers depend on, and a pgx-backed implementation. Handlers never
// see SQL — they talk to Repository, which makes them trivially fakeable in
// tests (see internal/api).
package db

import (
	"time"

	"github.com/google/uuid"
)

// User is identity only: which provider, which subject, an optional display
// email. It is never keyed by email.
type User struct {
	ID              uuid.UUID `json:"id"`
	Provider        string    `json:"provider"`
	ProviderSubject string    `json:"-"`
	Email           *string   `json:"email,omitempty"`
	CreatedAt       time.Time `json:"-"`
}

// VocabItem mirrors the on-device notebook row plus the sync metadata
// (client_uuid for idempotent upsert, updated_at for last-write-wins, deleted
// as a tombstone).
type VocabItem struct {
	ID          uuid.UUID `json:"-"`
	UserID      uuid.UUID `json:"-"`
	ClientUUID  uuid.UUID `json:"client_uuid"`
	SourceText  string    `json:"source_text"`
	Translation string    `json:"translation"`
	SrcLang     string    `json:"src_lang"`
	TgtLang     string    `json:"tgt_lang"`
	Engine      string    `json:"engine"`
	Tag         *string   `json:"tag,omitempty"`
	Deleted     bool      `json:"deleted"`
	CreatedAt   time.Time `json:"-"`
	UpdatedAt   time.Time `json:"updated_at"`
}

// RefreshToken is the server-side record backing a long-lived refresh token.
// Only a hash of the token is stored — the raw value lives solely in the
// client's Keychain.
type RefreshToken struct {
	TokenHash string
	UserID    uuid.UUID
	ExpiresAt time.Time
	CreatedAt time.Time
}

// UserSecret is one encrypted secret row: an opaque AES-256-GCM envelope
// (key_id ‖ nonce ‖ ciphertext+tag) keyed by (UserID, Name). The plaintext key
// never touches this struct — only Blob, which is meaningless without the
// process-held master key.
type UserSecret struct {
	UserID    uuid.UUID
	Name      string
	Blob      []byte
	UpdatedAt time.Time
}

// UpsertSecretParams is one encrypted secret write. UpdatedAt drives
// last-write-wins so an out-of-order/stale write cannot overwrite a newer row.
type UpsertSecretParams struct {
	UserID    uuid.UUID
	Name      string
	Blob      []byte
	UpdatedAt time.Time
}

// UpsertUserParams identifies an account at sign-in.
type UpsertUserParams struct {
	Provider        string
	ProviderSubject string
	Email           *string
}

// UpsertVocabParams is one row of a batch push.
type UpsertVocabParams struct {
	UserID      uuid.UUID
	ClientUUID  uuid.UUID
	SourceText  string
	Translation string
	SrcLang     string
	TgtLang     string
	Engine      string
	Tag         *string
	Deleted     bool
	UpdatedAt   time.Time
}
