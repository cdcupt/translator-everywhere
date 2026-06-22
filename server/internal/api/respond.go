package api

import (
	"encoding/json"
	"net/http"
)

// writeJSON serializes v as JSON with the given status.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if v != nil {
		_ = json.NewEncoder(w).Encode(v)
	}
}

// writeError emits a consistent { "error": msg } envelope.
func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// decodeJSON reads a JSON body into v, rejecting unknown fields. Returns false
// (after writing a 400) on failure.
func decodeJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		writeError(w, http.StatusBadRequest, "malformed request body")
		return false
	}
	return true
}

// decodeJSONBestEffort decodes a body without writing an error response; used
// for optional payloads (e.g. signout).
func decodeJSONBestEffort(r *http.Request, v any) error {
	return json.NewDecoder(r.Body).Decode(v)
}
