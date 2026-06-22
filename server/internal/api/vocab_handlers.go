package api

import (
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/cdcupt/translator-everywhere/server/internal/db"
)

// Field length caps (security: bound user-supplied text).
const (
	maxTextLen   = 8000
	maxLangLen   = 16
	maxEngineLen = 32
	maxTagLen    = 128
)

// allowedEngines / allowedLangsOK validate the small enums coming from clients.
var allowedEngines = map[string]bool{"free": true, "openai": true}

type vocabItemDTO struct {
	ClientUUID  string    `json:"client_uuid"`
	SourceText  string    `json:"source_text"`
	Translation string    `json:"translation"`
	SrcLang     string    `json:"src_lang"`
	TgtLang     string    `json:"tgt_lang"`
	Engine      string    `json:"engine"`
	Tag         *string   `json:"tag,omitempty"`
	Deleted     bool      `json:"deleted"`
	UpdatedAt   time.Time `json:"updated_at"`
}

type vocabPushRequest struct {
	Items []vocabItemDTO `json:"items"`
}

type vocabPushResponse struct {
	Applied    int            `json:"applied"`
	Conflicts  []vocabItemDTO `json:"conflicts"`
	ServerTime time.Time      `json:"server_time"`
}

type vocabPullResponse struct {
	Items      []vocabItemDTO `json:"items"`
	ServerTime time.Time      `json:"server_time"`
}

// handleVocabPull is the GET /vocab?since= half of sync: returns every row
// (including tombstones) changed after the cursor.
func (s *Server) handleVocabPull(w http.ResponseWriter, r *http.Request) {
	userID, ok := userIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}

	since := time.Time{}
	if raw := r.URL.Query().Get("since"); raw != "" {
		parsed, err := time.Parse(time.RFC3339, raw)
		if err != nil {
			writeError(w, http.StatusBadRequest, "since must be RFC3339")
			return
		}
		since = parsed
	}

	rows, err := s.Repo.ListVocabSince(r.Context(), userID, since)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not read vocab")
		return
	}

	items := make([]vocabItemDTO, 0, len(rows))
	for _, row := range rows {
		items = append(items, toDTO(row))
	}
	writeJSON(w, http.StatusOK, vocabPullResponse{
		Items:      items,
		ServerTime: time.Now().UTC(),
	})
}

// handleVocabPush is the POST /vocab half: a batch upsert keyed on
// (user_id, client_uuid) with per-row last-write-wins by updated_at. Idempotent
// — a re-pushed row updates rather than duplicates.
func (s *Server) handleVocabPush(w http.ResponseWriter, r *http.Request) {
	userID, ok := userIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}

	var req vocabPushRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if len(req.Items) > s.MaxBatch {
		writeError(w, http.StatusRequestEntityTooLarge, "batch too large")
		return
	}

	applied := 0
	conflicts := make([]vocabItemDTO, 0)
	for _, dto := range req.Items {
		params, err := dto.toParams(userID)
		if err != "" {
			writeError(w, http.StatusBadRequest, err)
			return
		}
		stored, wasApplied, dbErr := s.Repo.UpsertVocab(r.Context(), params)
		if dbErr != nil {
			writeError(w, http.StatusInternalServerError, "could not persist vocab")
			return
		}
		if wasApplied {
			applied++
		} else {
			// Server copy was newer — return it so the client reconciles.
			conflicts = append(conflicts, toDTO(stored))
		}
	}

	writeJSON(w, http.StatusOK, vocabPushResponse{
		Applied:    applied,
		Conflicts:  conflicts,
		ServerTime: time.Now().UTC(),
	})
}

// handleDeleteAccount wipes the user + all rows via cascade.
func (s *Server) handleDeleteAccount(w http.ResponseWriter, r *http.Request) {
	userID, ok := userIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if err := s.Repo.DeleteAccount(r.Context(), userID); err != nil {
		writeError(w, http.StatusInternalServerError, "could not delete account")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// toParams validates a DTO and converts it to a repository param. It returns a
// non-empty string describing the first validation failure.
func (d vocabItemDTO) toParams(userID uuid.UUID) (db.UpsertVocabParams, string) {
	cu, err := uuid.Parse(d.ClientUUID)
	if err != nil {
		return db.UpsertVocabParams{}, "client_uuid must be a UUID"
	}
	if d.UpdatedAt.IsZero() {
		return db.UpsertVocabParams{}, "updated_at is required"
	}
	if len(d.SourceText) > maxTextLen || len(d.Translation) > maxTextLen {
		return db.UpsertVocabParams{}, "text fields exceed length cap"
	}
	if len(d.SrcLang) > maxLangLen || len(d.TgtLang) > maxLangLen {
		return db.UpsertVocabParams{}, "lang fields exceed length cap"
	}
	if len(d.Engine) > maxEngineLen || !allowedEngines[d.Engine] {
		return db.UpsertVocabParams{}, "engine must be free|openai"
	}
	if d.Tag != nil && len(*d.Tag) > maxTagLen {
		return db.UpsertVocabParams{}, "tag exceeds length cap"
	}
	return db.UpsertVocabParams{
		UserID:      userID,
		ClientUUID:  cu,
		SourceText:  d.SourceText,
		Translation: d.Translation,
		SrcLang:     d.SrcLang,
		TgtLang:     d.TgtLang,
		Engine:      d.Engine,
		Tag:         d.Tag,
		Deleted:     d.Deleted,
		UpdatedAt:   d.UpdatedAt.UTC(),
	}, ""
}

func toDTO(row db.VocabItem) vocabItemDTO {
	return vocabItemDTO{
		ClientUUID:  row.ClientUUID.String(),
		SourceText:  row.SourceText,
		Translation: row.Translation,
		SrcLang:     row.SrcLang,
		TgtLang:     row.TgtLang,
		Engine:      row.Engine,
		Tag:         row.Tag,
		Deleted:     row.Deleted,
		UpdatedAt:   row.UpdatedAt.UTC(),
	}
}
