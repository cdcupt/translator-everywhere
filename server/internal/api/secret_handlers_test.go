package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/cdcupt/translator-everywhere/server/internal/db"
	"github.com/cdcupt/translator-everywhere/server/internal/secrets"
)

// testMasterKey is a valid base64 32-byte AES-256 key for the Sealer.
func testMasterKey(b byte) string {
	return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{b}, 32))
}

// newSecretServer builds a test server with a configured Sealer so /secret/*
// is live (not degraded to 503).
func newSecretServer(t *testing.T) (*Server, *db.FakeRepository) {
	t.Helper()
	srv, repo := newTestServer(t)
	sealer, err := secrets.NewSealer(testMasterKey(0x2b))
	if err != nil {
		t.Fatalf("NewSealer: %v", err)
	}
	srv.Sealer = sealer
	return srv, repo
}

// bearerFor mints a session JWT for an arbitrary user id so tests can model
// distinct users without going through the sign-in flow (which is pinned to one
// subject).
func bearerFor(t *testing.T, srv *Server, userID uuid.UUID) string {
	t.Helper()
	tok, err := srv.Sessions.IssueAccessToken(userID)
	if err != nil {
		t.Fatalf("issue access token: %v", err)
	}
	return tok
}

func TestSecretPutGetRoundTrip(t *testing.T) {
	srv, _ := newSecretServer(t)
	router := srv.Router()
	bearer := bearerFor(t, srv, uuid.New())

	const key = "sk-round-trip-1234567890"
	putRec := doJSON(t, router, http.MethodPut, "/secret/openai-key",
		map[string]string{"key": key}, bearer)
	if putRec.Code != http.StatusOK {
		t.Fatalf("PUT status = %d, body %s", putRec.Code, putRec.Body.String())
	}
	var putResp secretPutResponse
	if err := json.Unmarshal(putRec.Body.Bytes(), &putResp); err != nil {
		t.Fatalf("decode put resp: %v", err)
	}
	if putResp.UpdatedAt.IsZero() {
		t.Error("PUT response missing updated_at")
	}

	getRec := doJSON(t, router, http.MethodGet, "/secret/openai-key", nil, bearer)
	if getRec.Code != http.StatusOK {
		t.Fatalf("GET status = %d, body %s", getRec.Code, getRec.Body.String())
	}
	var getResp secretGetResponse
	if err := json.Unmarshal(getRec.Body.Bytes(), &getResp); err != nil {
		t.Fatalf("decode get resp: %v", err)
	}
	if getResp.Key != key {
		t.Errorf("round-trip key = %q, want %q", getResp.Key, key)
	}
	if !getResp.UpdatedAt.Equal(putResp.UpdatedAt) {
		t.Errorf("updated_at get=%v put=%v, want equal", getResp.UpdatedAt, putResp.UpdatedAt)
	}
}

func TestSecretGetCrossUserReturns404(t *testing.T) {
	srv, _ := newSecretServer(t)
	router := srv.Router()

	owner := bearerFor(t, srv, uuid.New())
	other := bearerFor(t, srv, uuid.New())

	if rec := doJSON(t, router, http.MethodPut, "/secret/openai-key",
		map[string]string{"key": "sk-owner-secret"}, owner); rec.Code != http.StatusOK {
		t.Fatalf("owner PUT: %d", rec.Code)
	}

	// A different user's GET must not read the owner's row.
	rec := doJSON(t, router, http.MethodGet, "/secret/openai-key", nil, other)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("cross-user GET status = %d, want 404 (no cross-user read)", rec.Code)
	}
}

func TestSecretPutOversizedReturns413(t *testing.T) {
	srv, _ := newSecretServer(t)
	router := srv.Router()
	bearer := bearerFor(t, srv, uuid.New())

	big := strings.Repeat("x", maxSecretBodyBytes+500)
	rec := doJSON(t, router, http.MethodPut, "/secret/openai-key",
		map[string]string{"key": big}, bearer)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized PUT status = %d, want 413", rec.Code)
	}

	// A normal-sized key still succeeds.
	ok := doJSON(t, router, http.MethodPut, "/secret/openai-key",
		map[string]string{"key": "sk-normal"}, bearer)
	if ok.Code != http.StatusOK {
		t.Fatalf("normal PUT status = %d, want 200", ok.Code)
	}
}

func TestSecretPutRejectsEmptyKey(t *testing.T) {
	srv, _ := newSecretServer(t)
	rec := doJSON(t, srv.Router(), http.MethodPut, "/secret/openai-key",
		map[string]string{"key": ""}, bearerFor(t, srv, uuid.New()))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("empty-key PUT status = %d, want 400", rec.Code)
	}
}

func TestSecretLastWriteWins(t *testing.T) {
	srv, repo := newSecretServer(t)
	router := srv.Router()
	userID := uuid.New()
	bearer := bearerFor(t, srv, userID)
	ctx := context.Background()

	// PUT "first" over HTTP (server stamps updated_at = now).
	putRec := doJSON(t, router, http.MethodPut, "/secret/openai-key",
		map[string]string{"key": "first"}, bearer)
	if putRec.Code != http.StatusOK {
		t.Fatalf("PUT first: %d", putRec.Code)
	}
	var first secretPutResponse
	_ = json.Unmarshal(putRec.Body.Bytes(), &first)

	seal := func(plain string) []byte {
		blob, err := srv.Sealer.Seal([]byte(plain), secretAAD(userID))
		if err != nil {
			t.Fatalf("seal: %v", err)
		}
		return blob
	}

	// A stale (older) write must be ignored by the LWW guard.
	if _, err := repo.UpsertSecret(ctx, db.UpsertSecretParams{
		UserID: userID, Name: secretName,
		Blob: seal("stale"), UpdatedAt: first.UpdatedAt.Add(-time.Hour),
	}); err != nil {
		t.Fatalf("stale upsert: %v", err)
	}
	if got := getSecretKey(t, router, bearer); got != "first" {
		t.Errorf("after stale write, key = %q, want unchanged 'first'", got)
	}

	// A newer write wins.
	if _, err := repo.UpsertSecret(ctx, db.UpsertSecretParams{
		UserID: userID, Name: secretName,
		Blob: seal("newer"), UpdatedAt: first.UpdatedAt.Add(time.Hour),
	}); err != nil {
		t.Fatalf("newer upsert: %v", err)
	}
	if got := getSecretKey(t, router, bearer); got != "newer" {
		t.Errorf("after newer write, key = %q, want 'newer'", got)
	}
}

func TestSecretDeleteThenGet404(t *testing.T) {
	srv, _ := newSecretServer(t)
	router := srv.Router()
	bearer := bearerFor(t, srv, uuid.New())

	if rec := doJSON(t, router, http.MethodPut, "/secret/openai-key",
		map[string]string{"key": "sk-to-delete"}, bearer); rec.Code != http.StatusOK {
		t.Fatalf("PUT: %d", rec.Code)
	}
	if rec := doJSON(t, router, http.MethodDelete, "/secret/openai-key", nil, bearer); rec.Code != http.StatusNoContent {
		t.Fatalf("DELETE status = %d, want 204", rec.Code)
	}
	if rec := doJSON(t, router, http.MethodGet, "/secret/openai-key", nil, bearer); rec.Code != http.StatusNotFound {
		t.Fatalf("GET after DELETE status = %d, want 404", rec.Code)
	}
	// DELETE is idempotent — a second one still 204s.
	if rec := doJSON(t, router, http.MethodDelete, "/secret/openai-key", nil, bearer); rec.Code != http.StatusNoContent {
		t.Fatalf("idempotent DELETE status = %d, want 204", rec.Code)
	}
}

func TestSecretAccountDeleteCascades(t *testing.T) {
	srv, repo := newSecretServer(t)
	router := srv.Router()
	userID := uuid.New()
	bearer := bearerFor(t, srv, userID)

	if rec := doJSON(t, router, http.MethodPut, "/secret/openai-key",
		map[string]string{"key": "sk-cascade"}, bearer); rec.Code != http.StatusOK {
		t.Fatalf("PUT: %d", rec.Code)
	}
	if rec := doJSON(t, router, http.MethodDelete, "/account", nil, bearer); rec.Code != http.StatusNoContent {
		t.Fatalf("DELETE /account status = %d, want 204", rec.Code)
	}
	// The secret row must be gone (cascade), both via the API and the repo.
	if rec := doJSON(t, router, http.MethodGet, "/secret/openai-key", nil, bearer); rec.Code != http.StatusNotFound {
		t.Fatalf("GET after account delete = %d, want 404 (cascade)", rec.Code)
	}
	if _, err := repo.GetSecret(context.Background(), userID, secretName); err == nil {
		t.Fatal("secret row survived account delete — cascade broken")
	}
}

func TestSecretNoPlaintextInLogs(t *testing.T) {
	srv, _ := newSecretServer(t)
	var buf bytes.Buffer
	srv.Logger = log.New(&buf, "", 0)
	router := srv.Router()
	userID := uuid.New()
	bearer := bearerFor(t, srv, userID)

	const sentinel = "sk-SENTINEL-do-not-log-9f8e7d6c"

	// Happy path PUT + GET.
	if rec := doJSON(t, router, http.MethodPut, "/secret/openai-key",
		map[string]string{"key": sentinel}, bearer); rec.Code != http.StatusOK {
		t.Fatalf("PUT: %d", rec.Code)
	}
	if got := getSecretKey(t, router, bearer); got != sentinel {
		t.Fatalf("GET key mismatch: %q", got)
	}

	// Force the decrypt error path: swap the master key so Open fails on GET.
	badSealer, err := secrets.NewSealer(testMasterKey(0x77))
	if err != nil {
		t.Fatalf("bad sealer: %v", err)
	}
	srv.Sealer = badSealer
	if rec := doJSON(t, router, http.MethodGet, "/secret/openai-key", nil, bearer); rec.Code != http.StatusInternalServerError {
		t.Fatalf("forced decrypt-error GET = %d, want 500", rec.Code)
	}

	logs := buf.String()
	if strings.Contains(logs, sentinel) {
		t.Fatalf("plaintext key leaked into logs:\n%s", logs)
	}
	// The error log must still identify the user (id only).
	if strings.Contains(logs, "decrypt failed") && !strings.Contains(logs, userID.String()) {
		t.Errorf("decrypt-error log should carry the user id")
	}
}

func TestSecretUnauthenticatedReturns401(t *testing.T) {
	srv, _ := newSecretServer(t)
	router := srv.Router()
	for _, m := range []string{http.MethodGet, http.MethodPut, http.MethodDelete} {
		rec := doJSON(t, router, m, "/secret/openai-key", map[string]string{"key": "x"}, "")
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s without token = %d, want 401", m, rec.Code)
		}
	}
}

func TestSecretUnconfiguredReturns503(t *testing.T) {
	srv, _ := newTestServer(t) // no Sealer → degraded mode
	router := srv.Router()
	bearer := bearerFor(t, srv, uuid.New())

	if rec := doJSON(t, router, http.MethodPut, "/secret/openai-key",
		map[string]string{"key": "sk-x"}, bearer); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("PUT with no master key = %d, want 503", rec.Code)
	}
	if rec := doJSON(t, router, http.MethodGet, "/secret/openai-key", nil, bearer); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("GET with no master key = %d, want 503", rec.Code)
	}
	// DELETE (opt-out) must work even when encryption is unconfigured.
	if rec := doJSON(t, router, http.MethodDelete, "/secret/openai-key", nil, bearer); rec.Code != http.StatusNoContent {
		t.Errorf("DELETE with no master key = %d, want 204", rec.Code)
	}
}

func TestSecretRateLimitReturns429(t *testing.T) {
	srv, _ := newSecretServer(t)
	router := srv.Router()
	bearer := bearerFor(t, srv, uuid.New())

	// The first secretRateLimit requests pass; the next is limited.
	for i := 0; i < secretRateLimit; i++ {
		rec := doJSON(t, router, http.MethodGet, "/secret/openai-key", nil, bearer)
		if rec.Code == http.StatusTooManyRequests {
			t.Fatalf("hit 429 early at request %d (limit %d)", i+1, secretRateLimit)
		}
	}
	rec := doJSON(t, router, http.MethodGet, "/secret/openai-key", nil, bearer)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("request %d status = %d, want 429", secretRateLimit+1, rec.Code)
	}
}

// getSecretKey does a GET and returns the decrypted key, failing on non-200.
func getSecretKey(t *testing.T, h http.Handler, bearer string) string {
	t.Helper()
	rec := doJSON(t, h, http.MethodGet, "/secret/openai-key", nil, bearer)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET status = %d, body %s", rec.Code, rec.Body.String())
	}
	var resp secretGetResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode get resp: %v", err)
	}
	return resp.Key
}
