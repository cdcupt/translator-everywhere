package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/cdcupt/translator-everywhere/server/internal/db"
)

// secretName is the single, handler-hardcoded slot for the OpenAI key. The
// db column is unconstrained, but no caller-supplied name is ever accepted —
// the slot is fixed here so a client can never address another slot.
const secretName = "openai-key"

// maxSecretBodyBytes caps the PUT body at 4 KB → 413 on overflow. A real OpenAI
// key is a few hundred bytes; anything larger is abuse or a bug.
const maxSecretBodyBytes = 4 << 10 // 4096

type secretPutRequest struct {
	Key string `json:"key"`
}

type secretPutResponse struct {
	UpdatedAt time.Time `json:"updated_at"`
}

type secretGetResponse struct {
	Key       string    `json:"key"`
	UpdatedAt time.Time `json:"updated_at"`
}

// secretAAD builds the AES-GCM additional-authenticated-data that binds a blob
// to exactly one user + slot: userID[16] ‖ "openai-key". A fresh buffer is built
// each call so the caller's uuid array is never aliased or mutated.
func secretAAD(userID uuid.UUID) []byte {
	aad := make([]byte, 0, len(userID)+len(secretName))
	aad = append(aad, userID[:]...)
	aad = append(aad, secretName...)
	return aad
}

// handlePutSecret encrypts the caller's key and upserts it (LWW). The user_id
// comes only from the verified JWT — never the body. Codes: 200 · 400 (empty) ·
// 413 (>4 KB) · 401 · 429 · 503 (no master key).
func (s *Server) handlePutSecret(w http.ResponseWriter, r *http.Request) {
	userID, ok := userIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if s.Sealer == nil {
		writeError(w, http.StatusServiceUnavailable, "secret sync temporarily unavailable")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxSecretBodyBytes)
	var req secretPutRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeError(w, http.StatusRequestEntityTooLarge, "key payload too large")
			return
		}
		writeError(w, http.StatusBadRequest, "malformed request body")
		return
	}
	if req.Key == "" {
		writeError(w, http.StatusBadRequest, "key is required")
		return
	}

	blob, err := s.Sealer.Seal([]byte(req.Key), secretAAD(userID))
	if err != nil {
		// Never log the key or blob — user_id only.
		s.logger().Printf("secret: seal failed for user %s: %v", userID, err)
		writeError(w, http.StatusInternalServerError, "could not store secret")
		return
	}

	stored, err := s.Repo.UpsertSecret(r.Context(), db.UpsertSecretParams{
		UserID:    userID,
		Name:      secretName,
		Blob:      blob,
		UpdatedAt: time.Now().UTC(),
	})
	if err != nil {
		s.logger().Printf("secret: upsert failed for user %s: %v", userID, err)
		writeError(w, http.StatusInternalServerError, "could not store secret")
		return
	}

	writeJSON(w, http.StatusOK, secretPutResponse{UpdatedAt: stored.UpdatedAt})
}

// handleGetSecret fetches + decrypts the caller's key. Because the row is keyed
// on the JWT user id, a request for another user's key simply misses → 404.
// Codes: 200 · 404 · 401 · 429 · 503.
func (s *Server) handleGetSecret(w http.ResponseWriter, r *http.Request) {
	userID, ok := userIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if s.Sealer == nil {
		writeError(w, http.StatusServiceUnavailable, "secret sync temporarily unavailable")
		return
	}

	row, err := s.Repo.GetSecret(r.Context(), userID, secretName)
	if errors.Is(err, db.ErrNotFound) {
		writeError(w, http.StatusNotFound, "no secret stored")
		return
	}
	if err != nil {
		s.logger().Printf("secret: read failed for user %s: %v", userID, err)
		writeError(w, http.StatusInternalServerError, "could not read secret")
		return
	}

	key, err := s.Sealer.Open(row.Blob, secretAAD(userID))
	if err != nil {
		// Wrong/rotated master key or a tampered row: fail closed, log user_id only.
		s.logger().Printf("secret: decrypt failed for user %s", userID)
		writeError(w, http.StatusInternalServerError, "could not read secret")
		return
	}

	writeJSON(w, http.StatusOK, secretGetResponse{Key: string(key), UpdatedAt: row.UpdatedAt})
}

// handleDeleteSecret removes the server copy. Idempotent, and does NOT depend on
// the Sealer (you can always opt out even if encryption is unconfigured).
// Codes: 204 · 401 · 429.
func (s *Server) handleDeleteSecret(w http.ResponseWriter, r *http.Request) {
	userID, ok := userIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if err := s.Repo.DeleteSecret(r.Context(), userID, secretName); err != nil {
		s.logger().Printf("secret: delete failed for user %s: %v", userID, err)
		writeError(w, http.StatusInternalServerError, "could not delete secret")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// secretRateKey keys the per-user rate limiter on the authenticated user id.
// This handler runs after authMiddleware, so the id is always present.
func secretRateKey(r *http.Request) (string, error) {
	if id, ok := userIDFromContext(r.Context()); ok {
		return id.String(), nil
	}
	return "", nil
}
