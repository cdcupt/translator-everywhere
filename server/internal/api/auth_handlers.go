package api

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"time"

	"github.com/cdcupt/translator-everywhere/server/internal/auth"
	"github.com/cdcupt/translator-everywhere/server/internal/db"
)

type googleSignInRequest struct {
	// New flow: the app captures the Desktop-loopback authorization code and the
	// server exchanges it (so Google's required client_secret stays server-side).
	Code         string `json:"code"`
	CodeVerifier string `json:"code_verifier"`
	RedirectURI  string `json:"redirect_uri"`
	// Legacy flow: a Google id_token the app already obtained. Kept for back-compat.
	IDToken string `json:"id_token"`
}

type userResponse struct {
	ID       string `json:"id"`
	Email    string `json:"email,omitempty"`
	Provider string `json:"provider"`
}

type sessionResponse struct {
	SessionJWT   string       `json:"session_jwt"`
	RefreshToken string       `json:"refresh_token"`
	User         userResponse `json:"user"`
}

type refreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

type refreshResponse struct {
	SessionJWT string `json:"session_jwt"`
}

// handleAppleCallback is the Sign in with Apple WEB-flow callback. Apple sends
// the authorization code here (form_post when name/email scope is requested,
// otherwise a query-string GET). We exchange the code for a verified id_token,
// upsert the user, mint our session, and 302 the browser back to the app's
// custom URL scheme so ASWebAuthenticationSession can capture the result.
//
// Contract (success): translator-everywhere://apple-callback?session=<jwt>&refresh=<token>&state=<state>
// Contract (failure): translator-everywhere://apple-callback?error=<msg>&state=<state>
func (s *Server) handleAppleCallback(w http.ResponseWriter, r *http.Request) {
	// ParseForm merges query + form_post body; Apple may use either.
	if err := r.ParseForm(); err != nil {
		s.redirectAppleError(w, r, "", "malformed callback request")
		return
	}
	state := r.Form.Get("state")
	code := r.Form.Get("code")

	if code == "" {
		// Missing code is a malformed callback, not an auth failure — 400 so the
		// caller (or a misconfigured Apple console) sees the problem directly.
		writeError(w, http.StatusBadRequest, "code is required")
		return
	}
	if s.AppleOAuth == nil {
		s.redirectAppleError(w, r, state, "apple sign-in is not configured")
		return
	}

	ctx := r.Context()
	identity, err := s.AppleOAuth.ExchangeCode(ctx, code)
	if err != nil {
		s.redirectAppleError(w, r, state, "could not verify apple sign-in")
		return
	}

	var email *string
	if identity.Email != "" {
		email = &identity.Email
	}
	user, err := s.Repo.UpsertUser(ctx, db.UpsertUserParams{
		Provider:        identity.Provider,
		ProviderSubject: identity.Subject,
		Email:           email,
	})
	if err != nil {
		s.redirectAppleError(w, r, state, "could not persist user")
		return
	}

	resp, err := s.issueSession(ctx, user)
	if err != nil {
		s.redirectAppleError(w, r, state, "could not issue session")
		return
	}

	s.redirectAppleSuccess(w, r, state, resp.SessionJWT, resp.RefreshToken)
}

// appleCallbackScheme returns the configured app scheme, defaulting if unset.
func (s *Server) appleCallbackScheme() string {
	if s.AppCallbackScheme != "" {
		return s.AppCallbackScheme
	}
	return DefaultAppCallbackScheme
}

// redirectAppleSuccess 302s back to the app with session + refresh + state.
func (s *Server) redirectAppleSuccess(w http.ResponseWriter, r *http.Request, state, session, refresh string) {
	q := url.Values{}
	q.Set("session", session)
	q.Set("refresh", refresh)
	if state != "" {
		q.Set("state", state)
	}
	s.redirectToApp(w, r, q)
}

// redirectAppleError 302s back to the app with an error message + state.
func (s *Server) redirectAppleError(w http.ResponseWriter, r *http.Request, state, msg string) {
	q := url.Values{}
	q.Set("error", msg)
	if state != "" {
		q.Set("state", state)
	}
	s.redirectToApp(w, r, q)
}

func (s *Server) redirectToApp(w http.ResponseWriter, r *http.Request, q url.Values) {
	target := s.appleCallbackScheme() + "://apple-callback?" + q.Encode()
	http.Redirect(w, r, target, http.StatusFound)
}

func (s *Server) handleGoogleSignIn(w http.ResponseWriter, r *http.Request) {
	var req googleSignInRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	switch {
	case req.Code != "":
		// New Desktop-loopback flow: exchange the code server-side.
		if s.GoogleOAuth == nil {
			writeError(w, http.StatusServiceUnavailable, "google sign-in is not configured")
			return
		}
		identity, err := s.GoogleOAuth.ExchangeCode(r.Context(), req.Code, req.CodeVerifier, req.RedirectURI)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "could not verify google sign-in")
			return
		}
		s.completeSignIn(w, r, identity)
	case req.IDToken != "":
		// Legacy flow: verify an id_token the app already obtained.
		s.signInWithProvider(w, r, s.Google, req.IDToken)
	default:
		writeError(w, http.StatusBadRequest, "code or id_token is required")
	}
}

// signInWithProvider verifies an identity token then runs the shared
// upsert-user → issue-session flow.
func (s *Server) signInWithProvider(w http.ResponseWriter, r *http.Request, verifier IdentityVerifier, token string) {
	identity, err := verifier.Verify(r.Context(), token)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid identity token")
		return
	}
	s.completeSignIn(w, r, identity)
}

// completeSignIn upserts the user for a verified identity, issues a session, and
// writes it. Shared by the id_token, Apple-code, and Google-code paths.
func (s *Server) completeSignIn(w http.ResponseWriter, r *http.Request, identity auth.Identity) {
	ctx := r.Context()

	var email *string
	if identity.Email != "" {
		email = &identity.Email
	}
	user, err := s.Repo.UpsertUser(ctx, db.UpsertUserParams{
		Provider:        identity.Provider,
		ProviderSubject: identity.Subject,
		Email:           email,
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not persist user")
		return
	}

	resp, err := s.issueSession(ctx, user)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not issue session")
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

// issueSession mints an access JWT + refresh token and persists the refresh
// record (hashed).
func (s *Server) issueSession(ctx context.Context, user db.User) (sessionResponse, error) {
	accessJWT, err := s.Sessions.IssueAccessToken(user.ID)
	if err != nil {
		return sessionResponse{}, err
	}
	rawRefresh, expiresAt, err := s.Sessions.NewRefreshToken()
	if err != nil {
		return sessionResponse{}, err
	}
	err = s.Repo.InsertRefreshToken(ctx, db.RefreshToken{
		TokenHash: auth.HashRefreshToken(rawRefresh),
		UserID:    user.ID,
		ExpiresAt: expiresAt,
	})
	if err != nil {
		return sessionResponse{}, err
	}

	out := sessionResponse{
		SessionJWT:   accessJWT,
		RefreshToken: rawRefresh,
		User: userResponse{
			ID:       user.ID.String(),
			Provider: user.Provider,
		},
	}
	if user.Email != nil {
		out.User.Email = *user.Email
	}
	return out, nil
}

func (s *Server) handleRefresh(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.RefreshToken == "" {
		writeError(w, http.StatusBadRequest, "refresh_token is required")
		return
	}
	ctx := r.Context()

	rec, err := s.Repo.GetRefreshToken(ctx, auth.HashRefreshToken(req.RefreshToken))
	if errors.Is(err, db.ErrNotFound) {
		writeError(w, http.StatusUnauthorized, "invalid refresh token")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not validate refresh token")
		return
	}
	if time.Now().After(rec.ExpiresAt) {
		writeError(w, http.StatusUnauthorized, "refresh token expired")
		return
	}

	accessJWT, err := s.Sessions.IssueAccessToken(rec.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not issue session")
		return
	}
	writeJSON(w, http.StatusOK, refreshResponse{SessionJWT: accessJWT})
}

func (s *Server) handleSignOut(w http.ResponseWriter, r *http.Request) {
	// Best-effort revoke: the body may carry the refresh token to drop. The
	// access token is disposed client-side regardless.
	var req refreshRequest
	if r.ContentLength > 0 {
		_ = decodeJSONBestEffort(r, &req)
	}
	if req.RefreshToken != "" {
		_ = s.Repo.DeleteRefreshToken(r.Context(), auth.HashRefreshToken(req.RefreshToken))
	}
	w.WriteHeader(http.StatusNoContent)
}
