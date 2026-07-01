package db

import (
	"context"
	"sync"
	"time"

	"github.com/google/uuid"
)

// FakeRepository is an in-memory Repository for handler and logic tests — no
// Postgres required. It is safe for concurrent use.
type FakeRepository struct {
	mu      sync.Mutex
	users   map[uuid.UUID]User
	byIdent map[string]uuid.UUID // provider|subject -> user id
	vocab   map[string]VocabItem // userID|clientUUID -> row
	refresh map[string]RefreshToken
	secrets map[string]UserSecret // userID|name -> encrypted row

	// DeleteAccountCalls records the user ids passed to DeleteAccount so tests
	// can assert the cascade path was taken.
	DeleteAccountCalls []uuid.UUID
}

// NewFakeRepository builds an empty fake.
func NewFakeRepository() *FakeRepository {
	return &FakeRepository{
		users:   map[uuid.UUID]User{},
		byIdent: map[string]uuid.UUID{},
		vocab:   map[string]VocabItem{},
		refresh: map[string]RefreshToken{},
		secrets: map[string]UserSecret{},
	}
}

var _ Repository = (*FakeRepository)(nil)

func identKey(provider, subject string) string { return provider + "|" + subject }
func vocabKey(userID, clientUUID uuid.UUID) string {
	return userID.String() + "|" + clientUUID.String()
}
func secretKey(userID uuid.UUID, name string) string {
	return userID.String() + "|" + name
}

func (f *FakeRepository) UpsertUser(_ context.Context, p UpsertUserParams) (User, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	key := identKey(p.Provider, p.ProviderSubject)
	if id, ok := f.byIdent[key]; ok {
		u := f.users[id]
		if p.Email != nil {
			u.Email = p.Email
		}
		f.users[id] = u
		return u, nil
	}
	u := User{
		ID:              uuid.New(),
		Provider:        p.Provider,
		ProviderSubject: p.ProviderSubject,
		Email:           p.Email,
		CreatedAt:       time.Now().UTC(),
	}
	f.users[u.ID] = u
	f.byIdent[key] = u.ID
	return u, nil
}

func (f *FakeRepository) GetUser(_ context.Context, id uuid.UUID) (User, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	u, ok := f.users[id]
	if !ok {
		return User{}, ErrNotFound
	}
	return u, nil
}

func (f *FakeRepository) UpsertVocab(_ context.Context, p UpsertVocabParams) (VocabItem, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	key := vocabKey(p.UserID, p.ClientUUID)
	existing, ok := f.vocab[key]
	if ok && !p.UpdatedAt.After(existing.UpdatedAt) {
		// Last-write-wins: stored row is newer or equal — reject the write and
		// report the authoritative row.
		return existing, false, nil
	}

	row := VocabItem{
		ID:          uuid.New(),
		UserID:      p.UserID,
		ClientUUID:  p.ClientUUID,
		SourceText:  p.SourceText,
		Translation: p.Translation,
		SrcLang:     p.SrcLang,
		TgtLang:     p.TgtLang,
		Engine:      p.Engine,
		Tag:         p.Tag,
		Deleted:     p.Deleted,
		UpdatedAt:   p.UpdatedAt,
	}
	if ok {
		row.ID = existing.ID
		row.CreatedAt = existing.CreatedAt
	} else {
		row.CreatedAt = p.UpdatedAt
	}
	f.vocab[key] = row
	return row, true, nil
}

func (f *FakeRepository) ListVocabSince(_ context.Context, userID uuid.UUID, since time.Time) ([]VocabItem, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	out := make([]VocabItem, 0)
	for _, row := range f.vocab {
		if row.UserID == userID && row.UpdatedAt.After(since) {
			out = append(out, row)
		}
	}
	// Deterministic ascending order by updated_at.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j-1].UpdatedAt.After(out[j].UpdatedAt); j-- {
			out[j-1], out[j] = out[j], out[j-1]
		}
	}
	return out, nil
}

func (f *FakeRepository) DeleteAccount(_ context.Context, userID uuid.UUID) error {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.DeleteAccountCalls = append(f.DeleteAccountCalls, userID)
	delete(f.users, userID)
	for k, v := range f.byIdent {
		if v == userID {
			delete(f.byIdent, k)
		}
	}
	for k, row := range f.vocab {
		if row.UserID == userID {
			delete(f.vocab, k)
		}
	}
	for k, t := range f.refresh {
		if t.UserID == userID {
			delete(f.refresh, k)
		}
	}
	// Cascade the encrypted secret row(s), mirroring the ON DELETE CASCADE the
	// Postgres FK gives us — so account-delete removes the server key copy.
	for k, s := range f.secrets {
		if s.UserID == userID {
			delete(f.secrets, k)
		}
	}
	return nil
}

func (f *FakeRepository) InsertRefreshToken(_ context.Context, t RefreshToken) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.refresh[t.TokenHash] = t
	return nil
}

func (f *FakeRepository) GetRefreshToken(_ context.Context, tokenHash string) (RefreshToken, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	t, ok := f.refresh[tokenHash]
	if !ok {
		return RefreshToken{}, ErrNotFound
	}
	return t, nil
}

func (f *FakeRepository) DeleteRefreshToken(_ context.Context, tokenHash string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.refresh, tokenHash)
	return nil
}

func (f *FakeRepository) UpsertSecret(_ context.Context, p UpsertSecretParams) (UserSecret, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	key := secretKey(p.UserID, p.Name)
	if existing, ok := f.secrets[key]; ok && p.UpdatedAt.Before(existing.UpdatedAt) {
		// Last-write-wins: stored row is strictly newer — ignore the stale write
		// and report the authoritative row. (Equal timestamps still overwrite,
		// matching the SQL guard's >=.)
		return existing, nil
	}
	// Store a copy of the blob so callers can't mutate our state through the slice.
	row := UserSecret{
		UserID:    p.UserID,
		Name:      p.Name,
		Blob:      append([]byte(nil), p.Blob...),
		UpdatedAt: p.UpdatedAt,
	}
	f.secrets[key] = row
	return row, nil
}

func (f *FakeRepository) GetSecret(_ context.Context, userID uuid.UUID, name string) (UserSecret, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	row, ok := f.secrets[secretKey(userID, name)]
	if !ok {
		return UserSecret{}, ErrNotFound
	}
	// Return a copy so the caller cannot mutate stored state.
	row.Blob = append([]byte(nil), row.Blob...)
	return row, nil
}

func (f *FakeRepository) DeleteSecret(_ context.Context, userID uuid.UUID, name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.secrets, secretKey(userID, name))
	return nil
}
