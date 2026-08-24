package relay

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	controllerClockSkew     = 90 * time.Second
	controllerNonceLifetime = 3 * time.Minute
	controllerProofBodyMax  = 1 << 20
)

type controllerPrincipal struct {
	ControllerID string
	TokenID      string
	Generation   string
	Name         string
	Platform     string
	Scopes       map[string]struct{}
}

type controllerContextKey struct{}

func controllerFromContext(ctx context.Context) (controllerPrincipal, bool) {
	principal, ok := ctx.Value(controllerContextKey{}).(controllerPrincipal)
	return principal, ok
}

func (s *server) withControllerToken(kind string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		principal, err := s.authenticateControllerRequest(r, kind, time.Now())
		if err != nil {
			writeErr(w, http.StatusUnauthorized, "controller_unauthorized")
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), controllerContextKey{}, principal)))
	}
}

func (s *server) withControllerScope(scope string, next http.HandlerFunc) http.HandlerFunc {
	return s.withControllerToken("access", func(w http.ResponseWriter, r *http.Request) {
		principal, ok := controllerFromContext(r.Context())
		if !ok {
			writeErr(w, http.StatusUnauthorized, "controller_unauthorized")
			return
		}
		if _, ok := principal.Scopes[scope]; !ok {
			writeErr(w, http.StatusForbidden, "insufficient_scope")
			return
		}
		next(w, r)
	})
}

func (s *server) authenticateControllerRequest(r *http.Request, kind string, now time.Time) (controllerPrincipal, error) {
	token := bearerToken(r)
	tokenID, tokenSecret, ok := strings.Cut(token, ".")
	if !ok || tokenID == "" || tokenSecret == "" || len(token) > 256 {
		return controllerPrincipal{}, errors.New("invalid bearer token")
	}
	wantPrefix := "cat_"
	if kind == "refresh" {
		wantPrefix = "crt_"
	}
	if !strings.HasPrefix(tokenID, wantPrefix) {
		return controllerPrincipal{}, errors.New("wrong token kind")
	}

	var principal controllerPrincipal
	var secretHash, storedKind, scopesJSON, status string
	var publicKeyDER []byte
	var expiresAt int64
	err := s.db.QueryRowContext(r.Context(), `
SELECT t.secret_hash,t.kind,t.expires_at,t.generation,c.id,c.name,c.platform,c.public_key_der,c.scopes_json,c.status
FROM controller_tokens t JOIN controllers c ON c.id=t.controller_id
WHERE t.id=? AND t.revoked_at IS NULL AND c.status='active'`, tokenID).Scan(
		&secretHash, &storedKind, &expiresAt, &principal.Generation, &principal.ControllerID,
		&principal.Name, &principal.Platform, &publicKeyDER, &scopesJSON, &status)
	if err != nil || storedKind != kind || status != "active" || expiresAt < now.Unix() ||
		subtle.ConstantTimeCompare([]byte(secretHash), []byte(hmacToken(s.cfg.SessionSecret, token))) != 1 {
		return controllerPrincipal{}, errors.New("invalid token")
	}
	principal.TokenID = tokenID

	timestamp, err := strconv.ParseInt(r.Header.Get("X-RCTL-Timestamp"), 10, 64)
	if err != nil || absDuration(now.Sub(time.Unix(timestamp, 0))) > controllerClockSkew {
		return controllerPrincipal{}, errors.New("invalid timestamp")
	}
	nonce := r.Header.Get("X-RCTL-Nonce")
	nonceBytes, err := base64.RawURLEncoding.DecodeString(nonce)
	if err != nil || len(nonceBytes) < 16 || len(nonceBytes) > 32 {
		return controllerPrincipal{}, errors.New("invalid nonce")
	}
	signature, err := base64.RawURLEncoding.DecodeString(r.Header.Get("X-RCTL-Signature"))
	if err != nil || len(signature) == 0 || len(signature) > 128 {
		return controllerPrincipal{}, errors.New("invalid signature")
	}
	body, err := readControllerProofBody(r)
	if err != nil {
		return controllerPrincipal{}, err
	}
	queryValues, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return controllerPrincipal{}, err
	}
	canonicalQuery, err := canonicalControllerQuery(queryValues)
	if err != nil {
		return controllerPrincipal{}, err
	}
	bodyHash := sha256.Sum256(body)
	message := controllerRequestProofMessage(
		tokenID, timestamp, nonce, r.Method, r.URL.EscapedPath(), canonicalQuery,
		base64.RawURLEncoding.EncodeToString(bodyHash[:]),
	)
	parsed, err := x509.ParsePKIXPublicKey(publicKeyDER)
	if err != nil {
		return controllerPrincipal{}, err
	}
	publicKey, ok := parsed.(*ecdsa.PublicKey)
	if !ok {
		return controllerPrincipal{}, errors.New("invalid controller key")
	}
	digest := sha256.Sum256(message)
	if !ecdsa.VerifyASN1(publicKey, digest[:], signature) {
		return controllerPrincipal{}, errors.New("invalid proof")
	}

	_, _ = s.db.ExecContext(r.Context(), `DELETE FROM controller_nonces WHERE expires_at<?`, now.Unix())
	if _, err := s.db.ExecContext(r.Context(), `INSERT INTO controller_nonces(controller_id,nonce,expires_at) VALUES(?,?,?)`,
		principal.ControllerID, nonce, now.Add(controllerNonceLifetime).Unix()); err != nil {
		return controllerPrincipal{}, errors.New("replayed nonce")
	}
	var scopes []string
	if json.Unmarshal([]byte(scopesJSON), &scopes) != nil {
		return controllerPrincipal{}, errors.New("invalid stored scopes")
	}
	principal.Scopes = make(map[string]struct{}, len(scopes))
	for _, scope := range scopes {
		principal.Scopes[scope] = struct{}{}
	}
	_, _ = s.db.ExecContext(r.Context(), `UPDATE controllers SET last_seen_at=? WHERE id=? AND (last_seen_at IS NULL OR last_seen_at<?)`,
		now.Unix(), principal.ControllerID, now.Add(-time.Minute).Unix())
	return principal, nil
}

func readControllerProofBody(r *http.Request) ([]byte, error) {
	if r.Body == nil {
		return nil, nil
	}
	limited := io.LimitReader(r.Body, controllerProofBodyMax+1)
	body, err := io.ReadAll(limited)
	if err != nil || len(body) > controllerProofBodyMax {
		return nil, errors.New("controller body too large")
	}
	_ = r.Body.Close()
	r.Body = io.NopCloser(bytes.NewReader(body))
	return body, nil
}

func controllerRequestProofMessage(tokenID string, timestamp int64, nonce, method, escapedPath, query, bodyHash string) []byte {
	return []byte(strings.Join([]string{
		"rctl-request-v1", tokenID, strconv.FormatInt(timestamp, 10), nonce,
		strings.ToUpper(method), escapedPath, query, bodyHash,
	}, "\n"))
}

func canonicalControllerQuery(values url.Values) (string, error) {
	type pair struct{ key, value string }
	pairs := make([]pair, 0)
	for key, list := range values {
		if strings.ContainsAny(key, "\r\n") {
			return "", errors.New("invalid query")
		}
		if len(list) == 0 {
			list = []string{""}
		}
		for _, value := range list {
			if strings.ContainsAny(value, "\r\n") {
				return "", errors.New("invalid query")
			}
			pairs = append(pairs, pair{rfc3986QueryEscape(key), rfc3986QueryEscape(value)})
		}
	}
	sort.Slice(pairs, func(i, j int) bool {
		if pairs[i].key == pairs[j].key {
			return pairs[i].value < pairs[j].value
		}
		return pairs[i].key < pairs[j].key
	})
	parts := make([]string, len(pairs))
	for i, item := range pairs {
		parts[i] = item.key + "=" + item.value
	}
	return strings.Join(parts, "&"), nil
}

func rfc3986QueryEscape(value string) string {
	return strings.ReplaceAll(url.QueryEscape(value), "+", "%20")
}

func absDuration(value time.Duration) time.Duration {
	if value < 0 {
		return -value
	}
	return value
}

func (s *server) handleControllerMe(w http.ResponseWriter, r *http.Request) {
	principal, ok := controllerFromContext(r.Context())
	if !ok {
		writeErr(w, http.StatusUnauthorized, "controller_unauthorized")
		return
	}
	scopes := make([]string, 0, len(principal.Scopes))
	for scope := range principal.Scopes {
		scopes = append(scopes, scope)
	}
	sort.Strings(scopes)
	writeJSON(w, http.StatusOK, map[string]any{
		"controller": map[string]any{
			"id": principal.ControllerID, "name": principal.Name,
			"platform": principal.Platform, "scopes": scopes,
		},
	})
}

func (s *server) handleRefreshControllerToken(w http.ResponseWriter, r *http.Request) {
	principal, ok := controllerFromContext(r.Context())
	if !ok {
		writeErr(w, http.StatusUnauthorized, "controller_unauthorized")
		return
	}
	now := time.Now()
	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "refresh_failed")
		return
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(r.Context(), `UPDATE controller_tokens SET revoked_at=? WHERE id=? AND kind='refresh' AND revoked_at IS NULL`, now.Unix(), principal.TokenID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "refresh_failed")
		return
	}
	if changed, _ := res.RowsAffected(); changed != 1 {
		writeErr(w, http.StatusUnauthorized, "refresh_replayed")
		return
	}
	if _, err := tx.ExecContext(r.Context(), `UPDATE controller_tokens SET revoked_at=? WHERE controller_id=? AND generation=? AND revoked_at IS NULL`,
		now.Unix(), principal.ControllerID, principal.Generation); err != nil {
		writeErr(w, http.StatusInternalServerError, "refresh_failed")
		return
	}
	tokens, err := s.createControllerTokens(r.Context(), tx, principal.ControllerID, now)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "refresh_failed")
		return
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusConflict, "refresh_conflict")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	s.audit(r, "controller_tokens_rotated", "controller_id", principal.ControllerID)
	writeJSON(w, http.StatusOK, map[string]any{"tokens": tokens})
}
