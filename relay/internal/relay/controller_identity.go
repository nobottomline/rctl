package relay

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"
)

const (
	controllerPairingDefaultTTL = 5 * time.Minute
	controllerPairingMinTTL     = time.Minute
	controllerPairingMaxTTL     = 10 * time.Minute
	controllerAccessTTL         = 10 * time.Minute
	controllerRefreshTTL        = 30 * 24 * time.Hour
	controllerNameMaxRunes      = 80
)

var controllerScopes = map[string]struct{}{
	"screen.view":        {},
	"device.control":     {},
	"audio.listen":       {},
	"microphone.talk":    {},
	"camera":             {},
	"files.read":         {},
	"files.write":        {},
	"terminal":           {},
	"system.destructive": {},
	"device.update":      {},
}

type controllerPairingRequest struct {
	Name       string   `json:"name"`
	Scopes     []string `json:"scopes"`
	TTLSeconds int64    `json:"ttl_seconds"`
}

type controllerClaimRequest struct {
	Secret    string `json:"secret"`
	Name      string `json:"name"`
	Platform  string `json:"platform"`
	PublicKey string `json:"public_key"`
	Proof     string `json:"proof"`
}

type controllerTokenPair struct {
	AccessToken      string `json:"access_token"`
	AccessExpiresAt  int64  `json:"access_expires_at"`
	RefreshToken     string `json:"refresh_token"`
	RefreshExpiresAt int64  `json:"refresh_expires_at"`
}

func normalizeControllerName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		name = "My controller"
	}
	runes := []rune(name)
	if len(runes) > controllerNameMaxRunes {
		name = string(runes[:controllerNameMaxRunes])
	}
	return name
}

func normalizeControllerScopes(input []string) ([]string, error) {
	if len(input) == 0 || len(input) > len(controllerScopes) {
		return nil, errors.New("invalid scope count")
	}
	seen := make(map[string]struct{}, len(input))
	for _, scope := range input {
		if _, ok := controllerScopes[scope]; !ok {
			return nil, errors.New("unknown controller scope")
		}
		seen[scope] = struct{}{}
	}
	out := make([]string, 0, len(seen))
	for scope := range seen {
		out = append(out, scope)
	}
	sort.Strings(out)
	return out, nil
}

func (s *server) relayIdentity(ctx context.Context) (string, error) {
	var value string
	err := s.db.QueryRowContext(ctx, `SELECT value FROM relay_metadata WHERE key='relay_id'`).Scan(&value)
	if err == nil {
		return value, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	value = base64.RawURLEncoding.EncodeToString(raw)
	_, err = s.db.ExecContext(ctx, `INSERT OR IGNORE INTO relay_metadata(key,value) VALUES('relay_id',?)`, value)
	if err != nil {
		return "", err
	}
	if err := s.db.QueryRowContext(ctx, `SELECT value FROM relay_metadata WHERE key='relay_id'`).Scan(&value); err != nil {
		return "", err
	}
	return value, nil
}

func (s *server) handleCreateControllerPairing(w http.ResponseWriter, r *http.Request) {
	var req controllerPairingRequest
	if err := readStrictJSON(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}
	scopes, err := normalizeControllerScopes(req.Scopes)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_scopes")
		return
	}
	ttl := controllerPairingDefaultTTL
	if req.TTLSeconds != 0 {
		ttl = time.Duration(req.TTLSeconds) * time.Second
	}
	if ttl < controllerPairingMinTTL || ttl > controllerPairingMaxTTL {
		writeErr(w, http.StatusBadRequest, "invalid_expiry")
		return
	}
	id, secret, err := newTokenPair("pair")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "token_generation_failed")
		return
	}
	now := time.Now()
	expiresAt := now.Add(ttl).Unix()
	scopesJSON, _ := json.Marshal(scopes)
	if _, err := s.db.ExecContext(r.Context(), `
INSERT INTO controller_pairings(id,secret_hash,name,scopes_json,expires_at,created_at)
VALUES(?,?,?,?,?,?)`, id, hmacToken(s.cfg.SessionSecret, id+"."+secret), normalizeControllerName(req.Name), string(scopesJSON), expiresAt, now.Unix()); err != nil {
		writeErr(w, http.StatusInternalServerError, "pairing_create_failed")
		return
	}
	relayID, err := s.relayIdentity(r.Context())
	if err != nil {
		_, _ = s.db.ExecContext(r.Context(), `DELETE FROM controller_pairings WHERE id=?`, id)
		writeErr(w, http.StatusInternalServerError, "relay_identity_failed")
		return
	}
	payload := map[string]any{
		"v": 1, "origin": strings.TrimRight(s.cfg.PublicURL, "/"), "pairing_id": id,
		"secret": secret, "expires_at": expiresAt, "protocol_major": protocolMajor,
		"relay_id": relayID,
	}
	w.Header().Set("Cache-Control", "no-store")
	s.audit(r, "controller_pairing_created", "pairing_id", id, "expires_at", expiresAt, "scopes", scopes)
	writeJSON(w, http.StatusCreated, map[string]any{"pairing": payload})
}

func (s *server) handleRevokeControllerPairing(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !strings.HasPrefix(id, "pair_") || len(id) > 64 {
		writeErr(w, http.StatusNotFound, "pairing_not_found")
		return
	}
	now := time.Now().Unix()
	res, err := s.db.ExecContext(r.Context(), `
UPDATE controller_pairings SET revoked_at=?
WHERE id=? AND used_at IS NULL AND revoked_at IS NULL AND expires_at>=?`, now, id, now)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "pairing_revoke_failed")
		return
	}
	if changed, _ := res.RowsAffected(); changed != 1 {
		writeErr(w, http.StatusNotFound, "pairing_not_found")
		return
	}
	s.audit(r, "controller_pairing_revoked", "pairing_id", id)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func parseControllerPublicKey(encoded string) (*ecdsa.PublicKey, []byte, string, error) {
	if encoded == "" || len(encoded) > 1024 {
		return nil, nil, "", errors.New("invalid public key")
	}
	der, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(der) == 0 || len(der) > 512 {
		return nil, nil, "", errors.New("invalid public key")
	}
	parsed, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, nil, "", err
	}
	key, ok := parsed.(*ecdsa.PublicKey)
	if !ok || key.Curve != elliptic.P256() || !key.Curve.IsOnCurve(key.X, key.Y) {
		return nil, nil, "", errors.New("public key must be P-256")
	}
	digest := sha256.Sum256(der)
	return key, der, base64.RawURLEncoding.EncodeToString(digest[:]), nil
}

func pairingProofMessage(id, secret, name, platform, fingerprint string) []byte {
	return []byte(strings.Join([]string{"rctl-pair-v1", id, secret, name, platform, fingerprint}, "\n"))
}

func verifyPairingProof(key *ecdsa.PublicKey, message []byte, encoded string) bool {
	if encoded == "" || len(encoded) > 256 {
		return false
	}
	signature, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(signature) == 0 || len(signature) > 128 {
		return false
	}
	digest := sha256.Sum256(message)
	return ecdsa.VerifyASN1(key, digest[:], signature)
}

func (s *server) handleClaimControllerPairing(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !strings.HasPrefix(id, "pair_") || len(id) > 64 {
		writeErr(w, http.StatusNotFound, "pairing_not_found")
		return
	}
	var req controllerClaimRequest
	if err := readStrictJSON(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if req.Platform != "ios" && req.Platform != "android" {
		writeErr(w, http.StatusBadRequest, "invalid_platform")
		return
	}
	name := normalizeControllerName(req.Name)
	key, der, fingerprint, err := parseControllerPublicKey(req.PublicKey)
	if err != nil || !verifyPairingProof(key, pairingProofMessage(id, req.Secret, name, req.Platform, fingerprint), req.Proof) {
		writeErr(w, http.StatusUnauthorized, "invalid_pairing_proof")
		return
	}
	now := time.Now()
	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "pairing_claim_failed")
		return
	}
	defer tx.Rollback()
	var secretHash, scopesJSON string
	var expiresAt int64
	var usedAt, revokedAt sql.NullInt64
	err = tx.QueryRowContext(r.Context(), `
SELECT secret_hash,scopes_json,expires_at,used_at,revoked_at FROM controller_pairings WHERE id=?`, id).
		Scan(&secretHash, &scopesJSON, &expiresAt, &usedAt, &revokedAt)
	if err != nil || usedAt.Valid || revokedAt.Valid || expiresAt < now.Unix() ||
		subtle.ConstantTimeCompare([]byte(secretHash), []byte(hmacToken(s.cfg.SessionSecret, id+"."+req.Secret))) != 1 {
		writeErr(w, http.StatusUnauthorized, "pairing_unavailable")
		return
	}
	controllerID, _, err := newTokenPair("ctl")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "token_generation_failed")
		return
	}
	if _, err = tx.ExecContext(r.Context(), `
INSERT INTO controllers(id,name,platform,public_key_der,public_key_sha256,scopes_json,status,created_at,last_seen_at)
VALUES(?,?,?,?,?,?, 'active',?,?)`, controllerID, name, req.Platform, der, fingerprint, scopesJSON, now.Unix(), now.Unix()); err != nil {
		writeErr(w, http.StatusConflict, "controller_key_already_registered")
		return
	}
	res, err := tx.ExecContext(r.Context(), `
UPDATE controller_pairings SET used_at=? WHERE id=? AND used_at IS NULL AND revoked_at IS NULL AND expires_at>=?`, now.Unix(), id, now.Unix())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "pairing_claim_failed")
		return
	}
	if changed, _ := res.RowsAffected(); changed != 1 {
		writeErr(w, http.StatusConflict, "pairing_already_used")
		return
	}
	tokens, err := s.createControllerTokens(r.Context(), tx, controllerID, now)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "token_generation_failed")
		return
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusConflict, "pairing_claim_failed")
		return
	}
	var scopes []string
	_ = json.Unmarshal([]byte(scopesJSON), &scopes)
	w.Header().Set("Cache-Control", "no-store")
	s.audit(r, "controller_paired", "pairing_id", id, "controller_id", controllerID, "platform", req.Platform)
	writeJSON(w, http.StatusCreated, map[string]any{
		"controller": map[string]any{"id": controllerID, "name": name, "platform": req.Platform, "scopes": scopes},
		"tokens":     tokens,
	})
}

func (s *server) createControllerTokens(ctx context.Context, tx *sql.Tx, controllerID string, now time.Time) (controllerTokenPair, error) {
	accessID, accessSecret, err := newTokenPair("cat")
	if err != nil {
		return controllerTokenPair{}, err
	}
	refreshID, refreshSecret, err := newTokenPair("crt")
	if err != nil {
		return controllerTokenPair{}, err
	}
	generation := randomHex(16)
	accessExpires, refreshExpires := now.Add(controllerAccessTTL).Unix(), now.Add(controllerRefreshTTL).Unix()
	for _, token := range []struct {
		id, secret, kind string
		expires          int64
	}{
		{accessID, accessSecret, "access", accessExpires},
		{refreshID, refreshSecret, "refresh", refreshExpires},
	} {
		if _, err := tx.ExecContext(ctx, `INSERT INTO controller_tokens(id,controller_id,kind,secret_hash,expires_at,created_at,generation) VALUES(?,?,?,?,?,?,?)`,
			token.id, controllerID, token.kind, hmacToken(s.cfg.SessionSecret, token.id+"."+token.secret), token.expires, now.Unix(), generation); err != nil {
			return controllerTokenPair{}, err
		}
	}
	return controllerTokenPair{
		AccessToken:      accessID + "." + accessSecret,
		AccessExpiresAt:  accessExpires,
		RefreshToken:     refreshID + "." + refreshSecret,
		RefreshExpiresAt: refreshExpires,
	}, nil
}

func (s *server) createControllerAccessToken(
	ctx context.Context,
	tx *sql.Tx,
	controllerID string,
	generation string,
	now time.Time,
) (string, int64, error) {
	accessID, accessSecret, err := newTokenPair("cat")
	if err != nil {
		return "", 0, err
	}
	accessToken := accessID + "." + accessSecret
	accessExpiresAt := now.Add(controllerAccessTTL).Unix()
	_, err = tx.ExecContext(ctx, `
INSERT INTO controller_tokens(id,controller_id,kind,secret_hash,expires_at,created_at,generation)
VALUES(?,?,?,?,?,?,?)`, accessID, controllerID, "access",
		hmacToken(s.cfg.SessionSecret, accessToken), accessExpiresAt, now.Unix(), generation)
	if err != nil {
		return "", 0, err
	}
	return accessToken, accessExpiresAt, nil
}

func (s *server) handleListControllers(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.QueryContext(r.Context(), `SELECT id,name,platform,scopes_json,status,created_at,last_seen_at,revoked_at FROM controllers ORDER BY created_at DESC`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "controller_list_failed")
		return
	}
	defer rows.Close()
	type item struct {
		ID         string   `json:"id"`
		Name       string   `json:"name"`
		Platform   string   `json:"platform"`
		Status     string   `json:"status"`
		Scopes     []string `json:"scopes"`
		CreatedAt  int64    `json:"created_at"`
		LastSeenAt *int64   `json:"last_seen_at,omitempty"`
		RevokedAt  *int64   `json:"revoked_at,omitempty"`
	}
	out := []item{}
	for rows.Next() {
		var v item
		var scopes string
		var last, revoked sql.NullInt64
		if err := rows.Scan(&v.ID, &v.Name, &v.Platform, &scopes, &v.Status, &v.CreatedAt, &last, &revoked); err != nil {
			writeErr(w, http.StatusInternalServerError, "controller_scan_failed")
			return
		}
		_ = json.Unmarshal([]byte(scopes), &v.Scopes)
		if last.Valid {
			v.LastSeenAt = &last.Int64
		}
		if revoked.Valid {
			v.RevokedAt = &revoked.Int64
		}
		out = append(out, v)
	}
	writeJSON(w, http.StatusOK, map[string]any{"controllers": out})
}

func (s *server) handleRenameController(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
	}
	if readStrictJSON(r, &req) != nil || strings.TrimSpace(req.Name) == "" {
		writeErr(w, http.StatusBadRequest, "invalid_name")
		return
	}
	name := normalizeControllerName(req.Name)
	res, err := s.db.ExecContext(r.Context(), `UPDATE controllers SET name=? WHERE id=?`, name, r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "controller_rename_failed")
		return
	}
	if n, _ := res.RowsAffected(); n != 1 {
		writeErr(w, http.StatusNotFound, "controller_not_found")
		return
	}
	s.audit(r, "controller_renamed", "controller_id", r.PathValue("id"))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "name": name})
}

func (s *server) handleRevokeController(w http.ResponseWriter, r *http.Request) {
	now := time.Now().Unix()
	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "controller_revoke_failed")
		return
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(r.Context(), `UPDATE controllers SET status='revoked',revoked_at=? WHERE id=? AND status='active'`, now, r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "controller_revoke_failed")
		return
	}
	if n, _ := res.RowsAffected(); n != 1 {
		writeErr(w, http.StatusNotFound, "controller_not_found")
		return
	}
	if _, err = tx.ExecContext(r.Context(), `UPDATE controller_tokens SET revoked_at=? WHERE controller_id=? AND revoked_at IS NULL`, now, r.PathValue("id")); err != nil {
		writeErr(w, http.StatusInternalServerError, "controller_revoke_failed")
		return
	}
	if err = tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, "controller_revoke_failed")
		return
	}
	s.closeControllerSignals(r.PathValue("id"))
	s.audit(r, "controller_revoked", "controller_id", r.PathValue("id"))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
