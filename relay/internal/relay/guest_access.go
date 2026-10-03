package relay

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

const guestCookie = "__Host-rctl_guest"
const guestClaimCookie = "__Host-rctl_guest_claim"
const guestCapability = "guest.scoped_sessions_v1"

type guestPrincipal struct {
	SessionID      string   `json:"session_id"`
	GrantID        string   `json:"grant_id"`
	DeviceID       string   `json:"-"`
	Label          string   `json:"label"`
	Permissions    []string `json:"permissions"`
	Revision       int64    `json:"authorization_revision"`
	ExpiresAt      int64    `json:"expires_at"`
	AllowDirect    bool     `json:"allow_direct"`
	credentialHash string   // transport authority; never part of the browser bootstrap
}
type guestContextKey struct{}

func guestFromContext(ctx context.Context) (guestPrincipal, bool) {
	p, ok := ctx.Value(guestContextKey{}).(guestPrincipal)
	return p, ok
}

// Grant mutation and resource registration share guestGrantsMu. Cancellation
// waits occur after releasing it so a closing resource can finish its DB checks.
type guestConnection struct {
	cancel    context.CancelFunc
	done      chan struct{}
	confirmed bool // written before closing done
	device    *deviceConn
	signalID  string
}

func normalizeGuestPermissions(input []string) ([]string, error) {
	if len(input) == 0 || len(input) > len(guestPermissionIDs) {
		return nil, errors.New("invalid permissions")
	}
	allowed := map[string]bool{}
	for _, p := range guestPermissionIDs {
		allowed[p] = true
	}
	set := map[string]bool{}
	for _, p := range input {
		if !allowed[p] {
			return nil, errors.New("unknown permission")
		}
		set[p] = true
	}
	// Initial WebRTC policy requires a screen session. Command-only sessions are
	// introduced with their own negotiated device dispatcher, never a proxy bypass.
	if !set["screen.view"] {
		return nil, errors.New("screen permission required")
	}
	result := make([]string, 0, len(set))
	for p := range set {
		result = append(result, p)
	}
	sort.Strings(result)
	return result, nil
}
func guestHas(p guestPrincipal, permission string) bool {
	for _, v := range p.Permissions {
		if v == permission {
			return true
		}
	}
	return false
}
func (s *server) guestHash(kind, value string) string {
	return hmacToken(s.cfg.SessionSecret, "rctl-guest-v1:"+kind+":"+value)
}

func (s *server) guestRoutes(mux *http.ServeMux) {
	admin := func(h http.HandlerFunc) http.HandlerFunc {
		return s.withAdmin(s.guestOrigin(s.withRateLimit("guest-admin", rateLimitConfig{Max: 60, Window: time.Minute}, h)))
	}
	mux.HandleFunc("POST /api/admin/guest-grants", admin(s.handleCreateGuestGrant))
	mux.HandleFunc("GET /api/admin/guest-grants", s.withAdmin(s.handleListGuestGrants))
	mux.HandleFunc("POST /api/admin/guest-grants/{id}/permissions", admin(s.handleGuestPermissions))
	mux.HandleFunc("POST /api/admin/guest-grants/{id}/revoke", admin(s.handleGuestRevoke))
	mux.HandleFunc("POST /api/admin/guest-grants/revoke-all", admin(s.handleGuestRevokeAll))
	mux.HandleFunc("POST /api/admin/guest-grants/{id}/delete", admin(s.handleGuestDelete))
	mux.HandleFunc("GET /share/{id}", s.withRateLimit("guest-shell", rateLimitConfig{Max: 60, Window: time.Minute}, s.handleGuestLanding))
	mux.HandleFunc("POST /api/guest/prepare", s.guestOrigin(s.withRateLimit("guest-claim", rateLimitConfig{Max: 20, Window: time.Minute}, s.handleGuestPrepare)))
	mux.HandleFunc("POST /api/guest/claim", s.guestOrigin(s.withRateLimit("guest-claim", rateLimitConfig{Max: 20, Window: time.Minute}, s.handleGuestClaim)))
	mux.HandleFunc("POST /api/guest/claim/ack", s.guestOrigin(s.withGuest(s.handleGuestAck)))
	mux.HandleFunc("GET /api/guest/session", s.withGuest(s.handleGuestSession))
	mux.HandleFunc("POST /api/guest/session/end", s.guestOrigin(s.withGuest(s.handleGuestEnd)))
	mux.HandleFunc("GET /guest/control", s.withGuest(s.handleGuestControl))
	mux.HandleFunc("GET /api/guest/signal", s.guestOrigin(s.withRateLimit("guest-signal", rateLimitConfig{Max: 60, Window: time.Minute}, s.withGuest(s.handleSignalWS))))
}

func (s *server) guestOrigin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		origin := r.Header.Get("Origin")
		expected := strings.TrimSuffix(s.cfg.PublicURL, "/")
		if origin == "" || origin != expected || r.Header.Get("Sec-Fetch-Site") == "cross-site" {
			writeErr(w, 403, "origin_rejected")
			return
		}
		if r.Method == "POST" {
			ct := strings.Split(r.Header.Get("Content-Type"), ";")[0]
			if ct != "application/json" {
				writeErr(w, 415, "json_required")
				return
			}
		}
		next(w, r)
	}
}
func cookieParts(r *http.Request, name string) (string, string, bool) {
	c, e := r.Cookie(name)
	if e != nil || len(c.Value) > 128 {
		return "", "", false
	}
	id, secret, ok := strings.Cut(c.Value, ".")
	return id, secret, ok && id != "" && secret != ""
}
func (s *server) setGuestCookie(w http.ResponseWriter, name, id, secret string, seconds int) {
	http.SetCookie(w, &http.Cookie{Name: name, Value: id + "." + secret, Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: seconds})
}
func (s *server) clearGuestCookie(w http.ResponseWriter, name string) {
	http.SetCookie(w, &http.Cookie{Name: name, Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: -1})
}
func (s *server) withGuest(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		p, e := s.authenticateGuest(r)
		if e != nil {
			if r.URL.Path == "/guest/control" {
				guestErrorPage(w, 401, "Your access has ended or this browser has no guest session. Ask the owner for a new invitation.")
			} else {
				writeErr(w, 401, "guest_access_ended")
			}
			return
		}
		if ok, _ := s.limiter.allow("guest-session:"+p.SessionID, rateLimitConfig{Max: 600, Window: time.Minute}, time.Now()); !ok {
			writeErr(w, 429, "rate_limited")
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), guestContextKey{}, p)))
	}
}
func (s *server) authenticateGuest(r *http.Request) (guestPrincipal, error) {
	var p guestPrincipal
	id, secret, ok := cookieParts(r, guestCookie)
	if !ok {
		return p, errors.New("missing cookie")
	}
	var hash, permissions string
	err := s.db.QueryRowContext(r.Context(), `SELECT x.id,g.id,g.device_id,g.label,g.permissions_json,g.authorization_revision,g.expires_at,g.allow_direct,x.secret_hash FROM guest_sessions x JOIN guest_grants g ON g.id=x.grant_id JOIN devices d ON d.id=g.device_id WHERE x.id=? AND x.ended_at IS NULL AND g.revoked_at IS NULL AND g.expires_at>? AND d.status='approved'`, id, time.Now().Unix()).Scan(&p.SessionID, &p.GrantID, &p.DeviceID, &p.Label, &permissions, &p.Revision, &p.ExpiresAt, &p.AllowDirect, &hash)
	if err != nil || subtle.ConstantTimeCompare([]byte(hash), []byte(s.guestHash("session", id+"."+secret))) != 1 {
		return p, errors.New("invalid session")
	}
	if json.Unmarshal([]byte(permissions), &p.Permissions) != nil {
		return p, errors.New("invalid grant")
	}
	normalized, e := normalizeGuestPermissions(p.Permissions)
	if e != nil {
		return p, e
	}
	p.Permissions = normalized
	p.credentialHash = hash
	return p, nil
}
func (s *server) guestGrantCurrent(ctx context.Context, p guestPrincipal) bool {
	var revision int64
	err := s.db.QueryRowContext(ctx, `SELECT g.authorization_revision FROM guest_grants g JOIN guest_sessions x ON x.grant_id=g.id JOIN devices d ON d.id=g.device_id WHERE g.id=? AND x.id=? AND g.device_id=? AND x.secret_hash=? AND x.ended_at IS NULL AND g.revoked_at IS NULL AND g.expires_at>? AND d.status='approved'`, p.GrantID, p.SessionID, p.DeviceID, p.credentialHash, time.Now().Unix()).Scan(&revision)
	return err == nil && revision == p.Revision
}
func (s *server) guestDeviceReady(deviceID string, allowDirect bool) string {
	if !s.cfg.EnableWebRTC {
		return "webrtc_disabled"
	}
	dc := s.getDevice(deviceID)
	if dc == nil {
		return "device_offline"
	}
	if !hasFeature(dc.features, guestCapability) {
		return "device_guest_access_not_supported"
	}
	if !allowDirect && (s.cfg.TurnSecret == "" || len(s.cfg.TurnURLs) == 0) {
		return "turn_unavailable"
	}
	return ""
}
func (s *server) handleCreateGuestGrant(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID    string   `json:"device_id"`
		Label       string   `json:"label"`
		Permissions []string `json:"permissions"`
		TTL         int64    `json:"ttl_seconds"`
		AllowDirect bool     `json:"allow_direct"`
	}
	if readStrictJSON(r, &req) != nil {
		writeErr(w, 400, "invalid_guest_grant")
		return
	}
	perms, e := normalizeGuestPermissions(req.Permissions)
	label := strings.TrimSpace(req.Label)
	if e != nil || len([]rune(label)) > 80 || req.TTL < 60 || req.TTL > 86400 {
		writeErr(w, 400, "invalid_guest_grant")
		return
	}
	if label == "" {
		label = "Guest"
	}
	if !s.deviceApproved(r.Context(), req.DeviceID) {
		writeErr(w, 403, "device_not_approved")
		return
	}
	if e := s.guestDeviceReady(req.DeviceID, req.AllowDirect); e != "" {
		writeErr(w, 409, e)
		return
	}
	origin, e := url.Parse(s.cfg.PublicURL)
	if e != nil || origin.Scheme != "https" || origin.Host == "" || origin.User != nil || origin.Path != "" && origin.Path != "/" || origin.RawQuery != "" || origin.Fragment != "" {
		writeErr(w, 409, "guest_https_required")
		return
	}
	id, secret, e := newTokenPair("guest")
	if e != nil {
		writeErr(w, 500, "token_generation_failed")
		return
	}
	now := time.Now().Unix()
	expiry := now + req.TTL
	deadline := min(expiry, now+900)
	encoded, _ := json.Marshal(perms)
	s.guestGrantsMu.Lock()
	defer s.guestGrantsMu.Unlock()
	var count int
	e = s.db.QueryRowContext(r.Context(), `SELECT count(*) FROM guest_grants WHERE revoked_at IS NULL AND expires_at>?`, now).Scan(&count)
	if e != nil || count >= 256 {
		writeErr(w, 409, "guest_grant_limit")
		return
	}
	_, e = s.db.ExecContext(r.Context(), `INSERT INTO guest_grants(id,device_id,label,permissions_json,expires_at,created_at,invitation_hash,claim_deadline,allow_direct) VALUES(?,?,?,?,?,?,?,?,?)`, id, req.DeviceID, label, string(encoded), expiry, now, s.guestHash("invitation", id+"."+secret), deadline, req.AllowDirect)
	if e != nil {
		writeErr(w, 500, "guest_create_failed")
		return
	}
	s.audit(r, "guest_grant_created", "grant_id", id, "permissions", perms, "expires_at", expiry, "allow_direct", req.AllowDirect)
	writeJSON(w, 201, map[string]any{"id": id, "invitation_url": strings.TrimSuffix(s.cfg.PublicURL, "/") + "/share/" + id + "#" + secret, "expires_at": expiry, "claim_deadline": deadline, "authorization_revision": 1})
}
func (s *server) handleListGuestGrants(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	rows, e := s.db.QueryContext(r.Context(), `SELECT g.id,g.device_id,d.name,g.label,g.permissions_json,g.authorization_revision,g.expires_at,g.created_at,g.revoked_at,g.claim_deadline,g.claimed_at,g.allow_direct,x.id,x.ended_at FROM guest_grants g JOIN devices d ON d.id=g.device_id LEFT JOIN guest_sessions x ON x.grant_id=g.id ORDER BY g.created_at DESC LIMIT 1000`)
	if e != nil {
		writeErr(w, 500, "guest_list_failed")
		return
	}
	defer rows.Close()
	result := []map[string]any{}
	now := time.Now().Unix()
	for rows.Next() {
		var id, device, name, label, encoded string
		var rev, expires, created, deadline int64
		var revoked, claimed, ended sql.NullInt64
		var session sql.NullString
		var direct bool
		if rows.Scan(&id, &device, &name, &label, &encoded, &rev, &expires, &created, &revoked, &deadline, &claimed, &direct, &session, &ended) != nil {
			writeErr(w, 500, "guest_list_failed")
			return
		}
		var permissions []string
		_ = json.Unmarshal([]byte(encoded), &permissions)
		status := "invited"
		if claimed.Valid {
			status = "active"
		}
		if !claimed.Valid && deadline <= now {
			status = "expired"
		}
		if expires <= now {
			status = "expired"
		}
		if ended.Valid {
			status = "ended"
		}
		if revoked.Valid {
			status = "revoked"
		}
		s.guestConnectionsMu.Lock()
		active := len(s.guestConnections[id])
		s.guestConnectionsMu.Unlock()
		result = append(result, map[string]any{"id": id, "device_id": device, "device_name": name, "label": label, "permissions": permissions, "authorization_revision": rev, "expires_at": expires, "created_at": created, "claim_deadline": deadline, "status": status, "connections": active, "allow_direct": direct})
	}
	if rows.Err() != nil {
		writeErr(w, 500, "guest_list_failed")
		return
	}
	writeJSON(w, 200, map[string]any{"grants": result, "permissions": guestPermissionIDs})
}
func (s *server) handleGuestPrepare(w http.ResponseWriter, r *http.Request) {
	id, secret, e := newTokenPair("claim")
	if e != nil {
		writeErr(w, 500, "token_generation_failed")
		return
	}
	now := time.Now().Unix()
	s.guestGrantsMu.Lock()
	defer s.guestGrantsMu.Unlock()
	_, _ = s.db.ExecContext(r.Context(), `DELETE FROM guest_claims WHERE expires_at<=?`, now)
	var count int
	if s.db.QueryRowContext(r.Context(), `SELECT count(*) FROM guest_claims`).Scan(&count) != nil || count >= 512 {
		writeErr(w, 429, "claim_capacity")
		return
	}
	if _, e = s.db.ExecContext(r.Context(), `INSERT INTO guest_claims(id,secret_hash,expires_at) VALUES(?,?,?)`, id, s.guestHash("claim", id+"."+secret), now+120); e != nil {
		writeErr(w, 500, "claim_prepare_failed")
		return
	}
	s.setGuestCookie(w, guestClaimCookie, id, secret, 120)
	writeJSON(w, 200, map[string]any{"ok": true})
}
func (s *server) handleGuestClaim(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ID     string `json:"invitation_id"`
		Secret string `json:"secret"`
	}
	if readStrictJSON(r, &req) != nil || len(req.ID) > 64 || len(req.Secret) != 43 {
		writeErr(w, 400, "invalid_invitation")
		return
	}
	if prior, err := s.authenticateGuest(r); err == nil && prior.GrantID != req.ID {
		writeErr(w, 409, "end_current_session_first")
		return
	}
	bindingID, bindingSecret, ok := cookieParts(r, guestClaimCookie)
	if !ok {
		writeErr(w, 401, "claim_binding_required")
		return
	}
	binding := s.guestHash("claim", bindingID+"."+bindingSecret)
	id, secret, e := newTokenPair("gsess")
	if e != nil {
		writeErr(w, 500, "token_generation_failed")
		return
	}
	s.guestGrantsMu.Lock()
	defer s.guestGrantsMu.Unlock()
	tx, e := s.db.BeginTx(r.Context(), nil)
	if e != nil {
		writeErr(w, 500, "guest_claim_failed")
		return
	}
	defer tx.Rollback()
	now := time.Now().Unix()
	var claimHash string
	if tx.QueryRowContext(r.Context(), `SELECT secret_hash FROM guest_claims WHERE id=? AND expires_at>?`, bindingID, now).Scan(&claimHash) != nil || subtle.ConstantTimeCompare([]byte(claimHash), []byte(binding)) != 1 {
		writeErr(w, 401, "claim_binding_required")
		return
	}
	var hash, device string
	var expiry, deadline int64
	var claimed, recovery sql.NullInt64
	var previousBinding sql.NullString
	var acknowledged, direct bool
	e = tx.QueryRowContext(r.Context(), `SELECT g.invitation_hash,g.device_id,g.expires_at,g.claim_deadline,g.claimed_at,g.claim_binding_hash,g.recovery_deadline,g.acknowledged,g.allow_direct FROM guest_grants g JOIN devices d ON d.id=g.device_id WHERE g.id=? AND g.revoked_at IS NULL AND d.status='approved'`, req.ID).Scan(&hash, &device, &expiry, &deadline, &claimed, &previousBinding, &recovery, &acknowledged, &direct)
	valid := e == nil && expiry > now && subtle.ConstantTimeCompare([]byte(hash), []byte(s.guestHash("invitation", req.ID+"."+req.Secret))) == 1
	if !valid || !claimed.Valid && deadline <= now || claimed.Valid && (acknowledged || recovery.Int64 <= now || !previousBinding.Valid || subtle.ConstantTimeCompare([]byte(previousBinding.String), []byte(binding)) != 1) {
		writeErr(w, 410, "invitation_unavailable")
		return
	}
	// Inspect the transport while holding the grant lock. Unsupported/offline
	// devices do not consume a usable invitation.
	if e := s.guestDeviceReady(device, direct); e != "" {
		writeErr(w, 409, e)
		return
	}
	if !claimed.Valid {
		if _, e = tx.ExecContext(r.Context(), `UPDATE guest_grants SET claimed_at=?,claim_binding_hash=?,recovery_deadline=? WHERE id=? AND claimed_at IS NULL`, now, binding, min(expiry, now+60), req.ID); e != nil {
			writeErr(w, 500, "guest_claim_failed")
			return
		}
	} else {
		// Recovery reuses the identity but rotates the cookie. Never create two
		// independently active sessions from one invitation.
		if e = tx.QueryRowContext(r.Context(), `SELECT id FROM guest_sessions WHERE grant_id=? AND ended_at IS NULL`, req.ID).Scan(&id); e != nil {
			writeErr(w, 410, "invitation_unavailable")
			return
		}
	}
	if _, e = tx.ExecContext(r.Context(), `INSERT INTO guest_sessions(id,grant_id,secret_hash,created_at) VALUES(?,?,?,?) ON CONFLICT(grant_id) DO UPDATE SET secret_hash=excluded.secret_hash`, id, req.ID, s.guestHash("session", id+"."+secret), now); e != nil {
		writeErr(w, 500, "guest_claim_failed")
		return
	}
	if e = tx.Commit(); e != nil {
		writeErr(w, 500, "guest_claim_failed")
		return
	}
	// Cancel a prior recovery credential's connections before replacing its cookie.
	s.cancelGuestConnections(req.ID)
	s.setGuestCookie(w, guestCookie, id, secret, int(expiry-now))
	s.auditAs(r, auditActor{Kind: "guest", ID: id, Label: "Guest"}, "guest_invitation_claimed", "grant_id", req.ID)
	writeJSON(w, 200, map[string]any{"ok": true, "expires_at": expiry})
}
func (s *server) handleGuestAck(w http.ResponseWriter, r *http.Request) {
	s.guestGrantsMu.Lock()
	defer s.guestGrantsMu.Unlock()
	// Recovery rotates a cookie without changing its session ID. Recheck after
	// taking the mutation lock so an already-authenticated old ACK cannot end
	// recovery for a replacement credential whose response was lost.
	p, err := s.authenticateGuest(r)
	if err != nil {
		writeErr(w, 401, "guest_access_ended")
		return
	}
	if _, e := s.db.ExecContext(r.Context(), `UPDATE guest_grants SET acknowledged=1,claim_binding_hash=NULL,recovery_deadline=NULL WHERE id=?`, p.GrantID); e != nil {
		writeErr(w, 500, "claim_ack_failed")
		return
	}
	s.clearGuestCookie(w, guestClaimCookie)
	writeJSON(w, 200, map[string]any{"ok": true})
}
func (s *server) handleGuestSession(w http.ResponseWriter, r *http.Request) {
	p, _ := guestFromContext(r.Context())
	writeJSON(w, 200, p)
}
func (s *server) handleGuestPermissions(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Permissions      []string `json:"permissions"`
		ExpectedRevision int64    `json:"expected_revision"`
	}
	if readStrictJSON(r, &req) != nil || req.ExpectedRevision < 1 || req.ExpectedRevision >= 9007199254740991 {
		writeErr(w, 400, "invalid_permissions_request")
		return
	}
	permissions, e := normalizeGuestPermissions(req.Permissions)
	if e != nil {
		writeErr(w, 400, "invalid_permissions")
		return
	}
	encoded, _ := json.Marshal(permissions)
	s.guestGrantsMu.Lock()
	var prior string
	var revision int64
	var expires int64
	var revoked sql.NullInt64
	e = s.db.QueryRowContext(r.Context(), `SELECT permissions_json,authorization_revision,expires_at,revoked_at FROM guest_grants WHERE id=?`, r.PathValue("id")).Scan(&prior, &revision, &expires, &revoked)
	if e != nil || revoked.Valid || expires <= time.Now().Unix() || revision != req.ExpectedRevision {
		s.guestGrantsMu.Unlock()
		writeErr(w, 409, "guest_permissions_changed")
		return
	}
	changed := prior != string(encoded)
	if changed {
		_, e = s.db.ExecContext(r.Context(), `UPDATE guest_grants SET permissions_json=?,authorization_revision=authorization_revision+1 WHERE id=? AND authorization_revision=?`, string(encoded), r.PathValue("id"), revision)
		if e != nil {
			s.guestGrantsMu.Unlock()
			writeErr(w, 500, "guest_permissions_failed")
			return
		}
		revision++
	}
	var closing []*guestConnection
	if changed {
		closing = s.cancelGuestConnections(r.PathValue("id"))
	}
	s.guestGrantsMu.Unlock()
	confirmed := waitGuestConnections(closing)
	if changed {
		s.audit(r, "guest_permissions_changed", "grant_id", r.PathValue("id"), "permissions", permissions, "authorization_revision", revision)
	}
	writeJSON(w, 200, map[string]any{"ok": true, "changed": changed, "authorization_revision": revision, "permissions": permissions, "disconnect_confirmed": confirmed})
}
func (s *server) handleGuestRevoke(w http.ResponseWriter, r *http.Request) {
	s.revokeGuest(w, r, false)
}
func (s *server) handleGuestRevokeAll(w http.ResponseWriter, r *http.Request) {
	s.revokeGuest(w, r, true)
}
func (s *server) revokeGuest(w http.ResponseWriter, r *http.Request, all bool) {
	s.guestGrantsMu.Lock()
	query := `UPDATE guest_grants SET revoked_at=?,authorization_revision=authorization_revision+1 WHERE revoked_at IS NULL`
	args := []any{time.Now().Unix()}
	if !all {
		query += ` AND id=?`
		args = append(args, r.PathValue("id"))
	}
	_, e := s.db.ExecContext(r.Context(), query, args...)
	if e != nil {
		s.guestGrantsMu.Unlock()
		writeErr(w, 500, "guest_revoke_failed")
		return
	}
	target := r.PathValue("id")
	if all {
		target = ""
	}
	closing := s.cancelGuestConnections(target)
	s.guestGrantsMu.Unlock()
	confirmed := waitGuestConnections(closing)
	s.audit(r, "guest_access_revoked", "grant_id", r.PathValue("id"), "all", all)
	writeJSON(w, 200, map[string]any{"ok": true, "disconnect_confirmed": confirmed})
}
func (s *server) handleGuestEnd(w http.ResponseWriter, r *http.Request) {
	s.guestGrantsMu.Lock()
	p, err := s.authenticateGuest(r)
	if err != nil {
		s.guestGrantsMu.Unlock()
		writeErr(w, 401, "guest_access_ended")
		return
	}
	_, e := s.db.ExecContext(r.Context(), `UPDATE guest_sessions SET ended_at=? WHERE id=?`, time.Now().Unix(), p.SessionID)
	closing := s.cancelGuestConnections(p.GrantID)
	s.guestGrantsMu.Unlock()
	if e != nil {
		writeErr(w, 500, "guest_end_failed")
		return
	}
	confirmed := waitGuestConnections(closing)
	s.clearGuestCookie(w, guestCookie)
	s.audit(r, "guest_session_ended", "grant_id", p.GrantID)
	writeJSON(w, 200, map[string]any{"ok": true, "disconnect_confirmed": confirmed})
}
func (s *server) handleGuestDelete(w http.ResponseWriter, r *http.Request) {
	s.guestGrantsMu.Lock()
	defer s.guestGrantsMu.Unlock()
	result, e := s.db.ExecContext(r.Context(), `DELETE FROM guest_grants WHERE id=? AND (revoked_at IS NOT NULL OR expires_at<=? OR (claimed_at IS NULL AND claim_deadline<=?) OR EXISTS(SELECT 1 FROM guest_sessions x WHERE x.grant_id=guest_grants.id AND x.ended_at IS NOT NULL))`, r.PathValue("id"), time.Now().Unix(), time.Now().Unix())
	if e != nil {
		writeErr(w, 500, "guest_delete_failed")
		return
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		writeErr(w, 409, "guest_grant_active")
		return
	}
	s.audit(r, "guest_grant_deleted", "grant_id", r.PathValue("id"))
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (s *server) registerGuestConnection(p guestPrincipal, id string, c *guestConnection) bool {
	s.guestConnectionsMu.Lock()
	defer s.guestConnectionsMu.Unlock()
	if s.guestConnections == nil {
		s.guestConnections = map[string]map[string]*guestConnection{}
	}
	if s.guestConnections[p.GrantID] == nil {
		s.guestConnections[p.GrantID] = map[string]*guestConnection{}
	}
	if len(s.guestConnections[p.GrantID]) >= 4 {
		return false
	}
	s.guestConnections[p.GrantID][id] = c
	return true
}
func (s *server) unregisterGuestConnection(grantID, id string) {
	s.guestConnectionsMu.Lock()
	defer s.guestConnectionsMu.Unlock()
	delete(s.guestConnections[grantID], id)
	if len(s.guestConnections[grantID]) == 0 {
		delete(s.guestConnections, grantID)
	}
}
func (s *server) cancelGuestConnections(grantID string) []*guestConnection {
	s.guestConnectionsMu.Lock()
	defer s.guestConnectionsMu.Unlock()
	result := []*guestConnection{}
	for id, connections := range s.guestConnections {
		if grantID != "" && id != grantID {
			continue
		}
		for _, c := range connections {
			c.cancel()
			result = append(result, c)
		}
	}
	return result
}
func waitGuestConnections(connections []*guestConnection) bool {
	deadline := time.NewTimer(4 * time.Second)
	defer deadline.Stop()
	confirmed := true
	for _, c := range connections {
		select {
		case <-c.done:
			confirmed = confirmed && c.confirmed
		case <-deadline.C:
			return false
		}
	}
	return confirmed
}
