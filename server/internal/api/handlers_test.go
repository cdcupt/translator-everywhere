package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/cdcupt/translator-everywhere/server/internal/auth"
	"github.com/cdcupt/translator-everywhere/server/internal/db"
)

// fakeVerifier is an IdentityVerifier stub.
type fakeVerifier struct {
	identity auth.Identity
	err      error
}

func (f fakeVerifier) Verify(_ context.Context, _ string) (auth.Identity, error) {
	return f.identity, f.err
}

func newTestServer(t *testing.T) (*Server, *db.FakeRepository) {
	t.Helper()
	repo := db.NewFakeRepository()
	sessions := auth.NewSessionManager("test-secret")
	apple := fakeVerifier{identity: auth.Identity{Provider: "apple", Subject: "apple-sub-1", Email: "a@example.com"}}
	google := fakeVerifier{identity: auth.Identity{Provider: "google", Subject: "google-sub-1"}}
	return NewServer(repo, sessions, apple, google), repo
}

func doJSON(t *testing.T, h http.Handler, method, target string, body any, bearer string) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encode body: %v", err)
		}
	}
	req := httptest.NewRequest(method, target, &buf)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// signIn drives POST /auth/apple and returns the session response.
func signIn(t *testing.T, srv *Server) sessionResponse {
	t.Helper()
	rec := doJSON(t, srv.Router(), http.MethodPost, "/auth/apple",
		appleSignInRequest{IdentityToken: "x"}, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("sign in: status %d, body %s", rec.Code, rec.Body.String())
	}
	var resp sessionResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode session: %v", err)
	}
	return resp
}

func TestHealthz(t *testing.T) {
	srv, _ := newTestServer(t)
	rec := doJSON(t, srv.Router(), http.MethodGet, "/healthz", nil, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
}

func TestAppleSignInIssuesSession(t *testing.T) {
	srv, repo := newTestServer(t)
	resp := signIn(t, srv)

	if resp.SessionJWT == "" || resp.RefreshToken == "" {
		t.Fatal("expected session + refresh tokens")
	}
	if resp.User.Provider != "apple" {
		t.Errorf("provider = %q", resp.User.Provider)
	}
	// The session JWT must verify back to the same user.
	id, err := srv.Sessions.VerifyAccessToken(resp.SessionJWT)
	if err != nil {
		t.Fatalf("verify issued jwt: %v", err)
	}
	if _, err := repo.GetUser(context.Background(), id); err != nil {
		t.Fatalf("user not persisted: %v", err)
	}
}

func TestSignInRejectsBadToken(t *testing.T) {
	repo := db.NewFakeRepository()
	sessions := auth.NewSessionManager("test-secret")
	bad := fakeVerifier{err: errors.New("invalid")}
	srv := NewServer(repo, sessions, bad, bad)

	rec := doJSON(t, srv.Router(), http.MethodPost, "/auth/apple",
		appleSignInRequest{IdentityToken: "x"}, "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}

func TestAuthMiddlewareRejectsMissingAndBlankToken(t *testing.T) {
	srv, _ := newTestServer(t)
	router := srv.Router()

	// No header.
	rec := doJSON(t, router, http.MethodGet, "/vocab", nil, "")
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("missing token: status = %d, want 401", rec.Code)
	}

	// Blank bearer value.
	req := httptest.NewRequest(http.MethodGet, "/vocab", nil)
	req.Header.Set("Authorization", "Bearer ")
	rec2 := httptest.NewRecorder()
	router.ServeHTTP(rec2, req)
	if rec2.Code != http.StatusUnauthorized {
		t.Errorf("blank token: status = %d, want 401", rec2.Code)
	}

	// Garbage token.
	rec3 := doJSON(t, router, http.MethodGet, "/vocab", nil, "not-a-jwt")
	if rec3.Code != http.StatusUnauthorized {
		t.Errorf("garbage token: status = %d, want 401", rec3.Code)
	}
}

func TestVocabPushIdempotentAndLastWriteWins(t *testing.T) {
	srv, _ := newTestServer(t)
	router := srv.Router()
	sess := signIn(t, srv)

	cu := uuid.New().String()
	t1 := time.Date(2026, 6, 20, 10, 0, 0, 0, time.UTC)
	t2 := t1.Add(time.Hour)

	push := func(text string, updatedAt time.Time) vocabPushResponse {
		body := vocabPushRequest{Items: []vocabItemDTO{{
			ClientUUID:  cu,
			SourceText:  text,
			Translation: "tr",
			SrcLang:     "ja",
			TgtLang:     "en",
			Engine:      "free",
			Deleted:     false,
			UpdatedAt:   updatedAt,
		}}}
		rec := doJSON(t, router, http.MethodPost, "/vocab", body, sess.SessionJWT)
		if rec.Code != http.StatusOK {
			t.Fatalf("push: status %d body %s", rec.Code, rec.Body.String())
		}
		var resp vocabPushResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
			t.Fatalf("decode push resp: %v", err)
		}
		return resp
	}

	// First push applies.
	if r := push("first", t1); r.Applied != 1 {
		t.Fatalf("first push applied = %d, want 1", r.Applied)
	}

	// Re-push the SAME row + timestamp: idempotent, not a duplicate, not newer
	// so not applied.
	r2 := push("first", t1)
	if r2.Applied != 0 || len(r2.Conflicts) != 1 {
		t.Fatalf("idempotent re-push: applied=%d conflicts=%d", r2.Applied, len(r2.Conflicts))
	}

	// Newer timestamp wins.
	if r := push("second", t2); r.Applied != 1 {
		t.Fatalf("newer push applied = %d, want 1", r.Applied)
	}

	// An OLDER timestamp loses (last-write-wins) and is reported as a conflict
	// carrying the server-authoritative ("second") row.
	r4 := push("stale", t1)
	if r4.Applied != 0 || len(r4.Conflicts) != 1 {
		t.Fatalf("stale push: applied=%d conflicts=%d", r4.Applied, len(r4.Conflicts))
	}
	if r4.Conflicts[0].SourceText != "second" {
		t.Errorf("conflict row = %q, want server-authoritative 'second'", r4.Conflicts[0].SourceText)
	}

	// Exactly one stored row for this client_uuid (idempotency held).
	rows, _ := srv.Repo.ListVocabSince(context.Background(), mustUserID(t, srv, sess), time.Time{})
	if len(rows) != 1 {
		t.Fatalf("stored rows = %d, want 1 (idempotent)", len(rows))
	}
	if rows[0].SourceText != "second" {
		t.Errorf("final row = %q, want 'second'", rows[0].SourceText)
	}
}

func TestVocabPullSinceIncludesTombstones(t *testing.T) {
	srv, _ := newTestServer(t)
	router := srv.Router()
	sess := signIn(t, srv)

	cu := uuid.New().String()
	base := time.Date(2026, 6, 20, 0, 0, 0, 0, time.UTC)

	// Create then tombstone the row.
	create := vocabPushRequest{Items: []vocabItemDTO{{
		ClientUUID: cu, SourceText: "hi", Translation: "tr",
		SrcLang: "ja", TgtLang: "en", Engine: "free", UpdatedAt: base,
	}}}
	if rec := doJSON(t, router, http.MethodPost, "/vocab", create, sess.SessionJWT); rec.Code != http.StatusOK {
		t.Fatalf("create: %d", rec.Code)
	}
	del := vocabPushRequest{Items: []vocabItemDTO{{
		ClientUUID: cu, SourceText: "hi", Translation: "tr",
		SrcLang: "ja", TgtLang: "en", Engine: "free", Deleted: true,
		UpdatedAt: base.Add(time.Hour),
	}}}
	if rec := doJSON(t, router, http.MethodPost, "/vocab", del, sess.SessionJWT); rec.Code != http.StatusOK {
		t.Fatalf("delete: %d", rec.Code)
	}

	// Pull since a cursor before the tombstone — must see the deleted row.
	since := base.Add(30 * time.Minute).Format(time.RFC3339)
	rec := doJSON(t, router, http.MethodGet, "/vocab?since="+since, nil, sess.SessionJWT)
	if rec.Code != http.StatusOK {
		t.Fatalf("pull: %d", rec.Code)
	}
	var resp vocabPullResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode pull: %v", err)
	}
	if len(resp.Items) != 1 || !resp.Items[0].Deleted {
		t.Fatalf("expected one tombstone, got %+v", resp.Items)
	}
}

func TestVocabPushRejectsInvalidEngine(t *testing.T) {
	srv, _ := newTestServer(t)
	sess := signIn(t, srv)
	body := vocabPushRequest{Items: []vocabItemDTO{{
		ClientUUID: uuid.New().String(), SourceText: "x", Translation: "y",
		SrcLang: "ja", TgtLang: "en", Engine: "bogus", UpdatedAt: time.Now(),
	}}}
	rec := doJSON(t, srv.Router(), http.MethodPost, "/vocab", body, sess.SessionJWT)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestRefreshFlow(t *testing.T) {
	srv, _ := newTestServer(t)
	router := srv.Router()
	sess := signIn(t, srv)

	rec := doJSON(t, router, http.MethodPost, "/auth/refresh",
		refreshRequest{RefreshToken: sess.RefreshToken}, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("refresh: status %d body %s", rec.Code, rec.Body.String())
	}
	var resp refreshResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if _, err := srv.Sessions.VerifyAccessToken(resp.SessionJWT); err != nil {
		t.Fatalf("refreshed jwt invalid: %v", err)
	}

	// Invalid refresh token is rejected.
	rec2 := doJSON(t, router, http.MethodPost, "/auth/refresh",
		refreshRequest{RefreshToken: "nope"}, "")
	if rec2.Code != http.StatusUnauthorized {
		t.Fatalf("bad refresh: status = %d, want 401", rec2.Code)
	}
}

func TestSignOutRevokesRefreshToken(t *testing.T) {
	srv, _ := newTestServer(t)
	router := srv.Router()
	sess := signIn(t, srv)

	rec := doJSON(t, router, http.MethodPost, "/auth/signout",
		refreshRequest{RefreshToken: sess.RefreshToken}, sess.SessionJWT)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("signout: status = %d, want 204", rec.Code)
	}

	// The revoked refresh token can no longer be used.
	rec2 := doJSON(t, router, http.MethodPost, "/auth/refresh",
		refreshRequest{RefreshToken: sess.RefreshToken}, "")
	if rec2.Code != http.StatusUnauthorized {
		t.Fatalf("refresh after signout: status = %d, want 401", rec2.Code)
	}
}

func TestDeleteAccountCascades(t *testing.T) {
	srv, repo := newTestServer(t)
	router := srv.Router()
	sess := signIn(t, srv)
	userID := mustUserID(t, srv, sess)

	rec := doJSON(t, router, http.MethodDelete, "/account", nil, sess.SessionJWT)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("delete account: status = %d, want 204", rec.Code)
	}
	if len(repo.DeleteAccountCalls) != 1 || repo.DeleteAccountCalls[0] != userID {
		t.Fatalf("expected DeleteAccount(%v), got %v", userID, repo.DeleteAccountCalls)
	}
	if _, err := repo.GetUser(context.Background(), userID); !errors.Is(err, db.ErrNotFound) {
		t.Fatalf("user should be gone, got err=%v", err)
	}
}

func mustUserID(t *testing.T, srv *Server, sess sessionResponse) uuid.UUID {
	t.Helper()
	id, err := srv.Sessions.VerifyAccessToken(sess.SessionJWT)
	if err != nil {
		t.Fatalf("verify session jwt: %v", err)
	}
	return id
}
