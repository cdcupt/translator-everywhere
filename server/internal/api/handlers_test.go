package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/cdcupt/translator-everywhere/server/internal/auth"
	"github.com/cdcupt/translator-everywhere/server/internal/db"
)

// fakeVerifier is an IdentityVerifier stub (Google path).
type fakeVerifier struct {
	identity auth.Identity
	err      error
}

func (f fakeVerifier) Verify(_ context.Context, _ string) (auth.Identity, error) {
	return f.identity, f.err
}

// fakeAppleExchanger is an AppleCodeExchanger stub: it maps a known good code to
// a verified Identity and fails on anything else.
type fakeAppleExchanger struct {
	identity auth.Identity
	err      error
}

func (f fakeAppleExchanger) ExchangeCode(_ context.Context, code string) (auth.Identity, error) {
	if f.err != nil {
		return auth.Identity{}, f.err
	}
	if code != "good-code" {
		return auth.Identity{}, errors.New("invalid code")
	}
	return f.identity, nil
}

// fakeGoogleExchanger is a GoogleCodeExchanger stub (Desktop-loopback path).
type fakeGoogleExchanger struct {
	identity auth.Identity
	err      error
}

func (f fakeGoogleExchanger) ExchangeCode(_ context.Context, code, _, _ string) (auth.Identity, error) {
	if f.err != nil {
		return auth.Identity{}, f.err
	}
	if code != "good-code" {
		return auth.Identity{}, errors.New("invalid code")
	}
	return f.identity, nil
}

func newTestServer(t *testing.T) (*Server, *db.FakeRepository) {
	t.Helper()
	repo := db.NewFakeRepository()
	sessions := auth.NewSessionManager("test-secret")
	apple := fakeAppleExchanger{identity: auth.Identity{Provider: "apple", Subject: "apple-sub-1", Email: "a@example.com"}}
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

// appleCallbackResult is the parsed redirect target the Apple callback 302s to.
type appleCallbackResult struct {
	session string
	refresh string
	state   string
	errMsg  string
}

// doAppleCallback drives the Apple web callback (GET, query-string) and parses
// the resulting translator-everywhere:// redirect URL.
func doAppleCallback(t *testing.T, srv *Server, code, state string) (*httptest.ResponseRecorder, appleCallbackResult) {
	t.Helper()
	q := url.Values{}
	if code != "" {
		q.Set("code", code)
	}
	if state != "" {
		q.Set("state", state)
	}
	rec := doJSON(t, srv.Router(), http.MethodGet, "/auth/apple/callback?"+q.Encode(), nil, "")

	var out appleCallbackResult
	if loc := rec.Header().Get("Location"); loc != "" {
		u, err := url.Parse(loc)
		if err != nil {
			t.Fatalf("parse redirect %q: %v", loc, err)
		}
		if u.Scheme != "translator-everywhere" || u.Host != "apple-callback" {
			t.Fatalf("redirect target = %q, want translator-everywhere://apple-callback", loc)
		}
		vals := u.Query()
		out = appleCallbackResult{
			session: vals.Get("session"),
			refresh: vals.Get("refresh"),
			state:   vals.Get("state"),
			errMsg:  vals.Get("error"),
		}
	}
	return rec, out
}

// signIn drives the Apple web callback happy path and returns the session.
func signIn(t *testing.T, srv *Server) sessionResponse {
	t.Helper()
	rec, res := doAppleCallback(t, srv, "good-code", "")
	if rec.Code != http.StatusFound {
		t.Fatalf("sign in: status %d, body %s", rec.Code, rec.Body.String())
	}
	if res.errMsg != "" {
		t.Fatalf("sign in error redirect: %q", res.errMsg)
	}
	if res.session == "" || res.refresh == "" {
		t.Fatalf("sign in: missing session/refresh in redirect")
	}
	return sessionResponse{SessionJWT: res.session, RefreshToken: res.refresh}
}

func TestGoogleSignInCodeFlow(t *testing.T) {
	srv, repo := newTestServer(t)
	srv.GoogleOAuth = fakeGoogleExchanger{identity: auth.Identity{Provider: "google", Subject: "g-sub-2", Email: "e@x.com"}}

	rec := doJSON(t, srv.Router(), http.MethodPost, "/auth/google",
		map[string]string{"code": "good-code", "code_verifier": "v", "redirect_uri": "http://127.0.0.1:1/oauth2redirect"}, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body %s", rec.Code, rec.Body.String())
	}
	var resp sessionResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	id, err := srv.Sessions.VerifyAccessToken(resp.SessionJWT)
	if err != nil {
		t.Fatalf("verify issued jwt: %v", err)
	}
	if user, err := repo.GetUser(context.Background(), id); err != nil || user.Provider != "google" {
		t.Fatalf("user not persisted as google: %+v err=%v", user, err)
	}
}

func TestGoogleSignInCodeFlowNotConfigured(t *testing.T) {
	srv, _ := newTestServer(t) // GoogleOAuth left nil
	rec := doJSON(t, srv.Router(), http.MethodPost, "/auth/google",
		map[string]string{"code": "good-code", "code_verifier": "v", "redirect_uri": "r"}, "")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503 when exchanger unconfigured", rec.Code)
	}
}

func TestGoogleSignInRejectsEmptyBody(t *testing.T) {
	srv, _ := newTestServer(t)
	rec := doJSON(t, srv.Router(), http.MethodPost, "/auth/google", map[string]string{}, "")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 when neither code nor id_token present", rec.Code)
	}
}

func TestGoogleSignInLegacyIDTokenStillWorks(t *testing.T) {
	srv, _ := newTestServer(t) // google fakeVerifier accepts any id_token
	rec := doJSON(t, srv.Router(), http.MethodPost, "/auth/google",
		map[string]string{"id_token": "anything"}, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 for legacy id_token path", rec.Code)
	}
}

func TestHealthz(t *testing.T) {
	srv, _ := newTestServer(t)
	rec := doJSON(t, srv.Router(), http.MethodGet, "/healthz", nil, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
}

func TestAppleCallbackHappyPathRedirectsToApp(t *testing.T) {
	srv, repo := newTestServer(t)

	rec, res := doAppleCallback(t, srv, "good-code", "state-xyz")
	if rec.Code != http.StatusFound {
		t.Fatalf("status = %d, want 302; body %s", rec.Code, rec.Body.String())
	}
	if res.session == "" || res.refresh == "" {
		t.Fatalf("redirect missing session/refresh: %+v", res)
	}
	if res.state != "state-xyz" {
		t.Errorf("state = %q, want state-xyz (round-tripped)", res.state)
	}
	if res.errMsg != "" {
		t.Errorf("unexpected error param: %q", res.errMsg)
	}

	// The session JWT must verify back to a persisted user.
	id, err := srv.Sessions.VerifyAccessToken(res.session)
	if err != nil {
		t.Fatalf("verify issued jwt: %v", err)
	}
	user, err := repo.GetUser(context.Background(), id)
	if err != nil {
		t.Fatalf("user not persisted: %v", err)
	}
	if user.Provider != "apple" {
		t.Errorf("provider = %q, want apple", user.Provider)
	}
}

func TestAppleCallbackAcceptsFormPost(t *testing.T) {
	srv, _ := newTestServer(t)

	form := url.Values{}
	form.Set("code", "good-code")
	form.Set("state", "fp-state")
	req := httptest.NewRequest(http.MethodPost, "/auth/apple/callback", bytes.NewBufferString(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)

	if rec.Code != http.StatusFound {
		t.Fatalf("form_post status = %d, want 302; body %s", rec.Code, rec.Body.String())
	}
	loc := rec.Header().Get("Location")
	u, err := url.Parse(loc)
	if err != nil {
		t.Fatalf("parse redirect: %v", err)
	}
	if u.Query().Get("session") == "" {
		t.Fatalf("form_post redirect missing session: %q", loc)
	}
	if u.Query().Get("state") != "fp-state" {
		t.Errorf("state = %q, want fp-state", u.Query().Get("state"))
	}
}

func TestAppleCallbackBadCodeRedirectsError(t *testing.T) {
	srv, _ := newTestServer(t)

	rec, res := doAppleCallback(t, srv, "wrong-code", "st")
	if rec.Code != http.StatusFound {
		t.Fatalf("status = %d, want 302", rec.Code)
	}
	if res.errMsg == "" {
		t.Fatalf("expected error param in redirect, got %+v", res)
	}
	if res.session != "" || res.refresh != "" {
		t.Errorf("error redirect must not carry tokens: %+v", res)
	}
	if res.state != "st" {
		t.Errorf("state = %q, want st (preserved on error)", res.state)
	}
}

func TestAppleCallbackMissingCodeReturns400(t *testing.T) {
	srv, _ := newTestServer(t)

	rec, _ := doAppleCallback(t, srv, "", "st")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestAppleCallbackNotConfiguredRedirectsError(t *testing.T) {
	repo := db.NewFakeRepository()
	sessions := auth.NewSessionManager("test-secret")
	google := fakeVerifier{identity: auth.Identity{Provider: "google", Subject: "g"}}
	// nil AppleOAuth = Apple web auth not configured.
	srv := NewServer(repo, sessions, nil, google)

	rec, res := doAppleCallback(t, srv, "good-code", "")
	if rec.Code != http.StatusFound {
		t.Fatalf("status = %d, want 302", rec.Code)
	}
	if res.errMsg == "" {
		t.Fatalf("expected error redirect when Apple not configured")
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
