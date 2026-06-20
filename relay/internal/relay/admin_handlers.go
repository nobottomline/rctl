package relay

import (
	"crypto/subtle"
	"database/sql"
	"net/http"
	"strconv"
	"strings"
	"time"

	"nhooyr.io/websocket"
)

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleRoot(w http.ResponseWriter, r *http.Request) {
	http.Redirect(w, r, "/admin", http.StatusFound)
}

func (s *server) handleAdminLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Secret string `json:"secret"`
	}
	if err := readJSON(r, &req); err != nil {
		s.audit(r, "admin_login_failed", "reason", "invalid_json")
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if subtle.ConstantTimeCompare([]byte(req.Secret), []byte(s.cfg.AdminSecret)) != 1 {
		s.audit(r, "admin_login_failed", "reason", "invalid_secret")
		writeErr(w, http.StatusUnauthorized, "invalid_secret")
		return
	}
	sessionID, sessionSecret, err := newTokenPair("sess")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "token_generation_failed")
		return
	}
	now := time.Now()
	ua := r.UserAgent()
	if len(ua) > 200 {
		ua = ua[:200]
	}
	// Sec-CH-UA client hints distinguish Brave/Edge/Opera, which all share Chrome's
	// User-Agent string. Sent by Chromium browsers on secure origins; empty otherwise.
	hints := r.Header.Get("Sec-Ch-Ua")
	if len(hints) > 256 {
		hints = hints[:256]
	}
	_, err = s.db.ExecContext(r.Context(),
		`INSERT INTO sessions(id, secret_hash, expires_at, created_at, last_seen_at, ip, user_agent, client_hints) VALUES(?,?,?,?,?,?,?,?)`,
		sessionID, hmacToken(s.cfg.SessionSecret, sessionSecret), now.Add(s.cfg.SessionLifetime).Unix(), now.Unix(), now.Unix(), s.clientIP(r), ua, hints)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "session_create_failed")
		return
	}
	s.audit(r, "admin_login_succeeded", "session_id", sessionID)
	http.SetCookie(w, &http.Cookie{
		Name:     "rctl_session",
		Value:    sessionID + "." + sessionSecret,
		Path:     "/",
		HttpOnly: true,
		Secure:   s.cfg.CookieSecure,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   int(s.cfg.SessionLifetime.Seconds()),
	})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleAdminLogout(w http.ResponseWriter, r *http.Request) {
	sessionID := ""
	if c, err := r.Cookie("rctl_session"); err == nil {
		id, _, ok := strings.Cut(c.Value, ".")
		if ok {
			sessionID = id
			_, _ = s.db.ExecContext(r.Context(), `DELETE FROM sessions WHERE id=?`, sessionID)
		}
	}
	s.audit(r, "admin_logout", "session_id", sessionID)
	s.clearSessionCookie(w)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleListSessions(w http.ResponseWriter, r *http.Request) {
	currentID, _, _ := parseSessionCookie(r)
	now := time.Now().Unix()
	_, _ = s.db.ExecContext(r.Context(), `DELETE FROM sessions WHERE expires_at<?`, now)
	rows, err := s.db.QueryContext(r.Context(), `
SELECT id, expires_at, created_at, last_seen_at, ip, user_agent, client_hints
FROM sessions
WHERE expires_at>=?
ORDER BY last_seen_at DESC`, now)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "session_list_failed")
		return
	}
	defer rows.Close()

	type session struct {
		ID          string `json:"id"`
		Current     bool   `json:"current"`
		ExpiresAt   int64  `json:"expires_at"`
		CreatedAt   int64  `json:"created_at"`
		LastSeenAt  int64  `json:"last_seen_at"`
		IP          string `json:"ip"`
		UserAgent   string `json:"user_agent"`
		ClientHints string `json:"client_hints"`
	}
	out := []session{}
	for rows.Next() {
		var item session
		var ip, ua, ch sql.NullString
		if err := rows.Scan(&item.ID, &item.ExpiresAt, &item.CreatedAt, &item.LastSeenAt, &ip, &ua, &ch); err != nil {
			writeErr(w, http.StatusInternalServerError, "session_scan_failed")
			return
		}
		item.IP = ip.String
		item.UserAgent = ua.String
		item.ClientHints = ch.String
		item.Current = item.ID == currentID
		out = append(out, item)
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": out})
}

func (s *server) handleListAudit(w http.ResponseWriter, r *http.Request) {
	limit := 100
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}
	rows, err := s.db.QueryContext(r.Context(), `
SELECT id, ts, event, ip, session_id, method, path, detail
FROM audit_log
ORDER BY id DESC
LIMIT ?`, limit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "audit_list_failed")
		return
	}
	defer rows.Close()

	type entry struct {
		ID        int64  `json:"id"`
		TS        int64  `json:"ts"`
		Event     string `json:"event"`
		IP        string `json:"ip"`
		SessionID string `json:"session_id,omitempty"`
		Method    string `json:"method"`
		Path      string `json:"path"`
		Detail    string `json:"detail,omitempty"`
	}
	out := []entry{}
	for rows.Next() {
		var item entry
		var ip, sid, method, path, detail sql.NullString
		if err := rows.Scan(&item.ID, &item.TS, &item.Event, &ip, &sid, &method, &path, &detail); err != nil {
			writeErr(w, http.StatusInternalServerError, "audit_scan_failed")
			return
		}
		item.IP = ip.String
		item.SessionID = sid.String
		item.Method = method.String
		item.Path = path.String
		item.Detail = detail.String
		out = append(out, item)
	}
	writeJSON(w, http.StatusOK, map[string]any{"audit": out})
}

func (s *server) handleRevokeSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	currentID, _, _ := parseSessionCookie(r)
	res, err := s.db.ExecContext(r.Context(), `DELETE FROM sessions WHERE id=?`, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "session_revoke_failed")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "session_not_found")
		return
	}
	if id == currentID {
		s.clearSessionCookie(w)
	}
	s.audit(r, "admin_session_revoked", "session_id", id, "current_revoked", id == currentID)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "current_revoked": id == currentID})
}

func (s *server) handleRevokeOtherSessions(w http.ResponseWriter, r *http.Request) {
	currentID, _, ok := parseSessionCookie(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	res, err := s.db.ExecContext(r.Context(), `DELETE FROM sessions WHERE id<>?`, currentID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "session_revoke_failed")
		return
	}
	n, _ := res.RowsAffected()
	s.audit(r, "admin_other_sessions_revoked", "current_session_id", currentID, "revoked", n)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "revoked": n})
}

func (s *server) handleRevokeAllSessions(w http.ResponseWriter, r *http.Request) {
	res, err := s.db.ExecContext(r.Context(), `DELETE FROM sessions`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "session_revoke_failed")
		return
	}
	n, _ := res.RowsAffected()
	s.clearSessionCookie(w)
	s.audit(r, "admin_all_sessions_revoked", "revoked", n)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "revoked": n, "current_revoked": true})
}

func (s *server) clearSessionCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{Name: "rctl_session", Value: "", Path: "/", MaxAge: -1, HttpOnly: true, Secure: s.cfg.CookieSecure, SameSite: http.SameSiteStrictMode})
}

const maxEnrollmentTTL = 90 * 24 * time.Hour

// neverExpiresUnix (2100-01-01 UTC) is the expiry stored for "never" tokens —
// far enough out to be effectively permanent while staying a real timestamp.
const neverExpiresUnix = 4102444800

func (s *server) handleCreateEnrollment(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Label      string `json:"label"`
		TTLSeconds int64  `json:"ttl_seconds"`
	}
	_ = readJSON(r, &req) // body is optional (curl-friendly)

	now := time.Now()
	var expiresAt time.Time
	if req.TTLSeconds < 0 {
		expiresAt = time.Unix(neverExpiresUnix, 0) // never
	} else {
		ttl := s.cfg.TokenTTL
		if req.TTLSeconds > 0 {
			ttl = time.Duration(req.TTLSeconds) * time.Second
			if ttl < time.Minute {
				ttl = time.Minute
			}
			if ttl > maxEnrollmentTTL {
				ttl = maxEnrollmentTTL
			}
		}
		expiresAt = now.Add(ttl)
	}
	label := strings.TrimSpace(req.Label)
	if n := []rune(label); len(n) > 80 {
		label = string(n[:80])
	}

	tokenID, tokenSecret, err := newTokenPair("enroll")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "token_generation_failed")
		return
	}
	token := tokenID + "." + tokenSecret
	_, err = s.db.ExecContext(r.Context(),
		`INSERT INTO enrollments(id, token_hash, expires_at, created_at, label) VALUES(?,?,?,?,?)`,
		tokenID, hashToken(token), expiresAt.Unix(), now.Unix(), label)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "enrollment_create_failed")
		return
	}
	s.audit(r, "admin_enrollment_created", "enrollment_id", tokenID, "expires_at", expiresAt.UTC().Format(time.RFC3339))
	writeJSON(w, http.StatusCreated, map[string]any{
		"token":      token,
		"expires_at": expiresAt.UTC().Format(time.RFC3339),
		"relay_url":  s.deviceWebSocketURL(),
	})
}

func enrollmentStatus(now int64, expiresAt int64, usedAt, revokedAt sql.NullInt64) string {
	switch {
	case revokedAt.Valid:
		return "revoked"
	case usedAt.Valid:
		return "used"
	case expiresAt < now:
		return "expired"
	default:
		return "active"
	}
}

func (s *server) handleListEnrollments(w http.ResponseWriter, r *http.Request) {
	now := time.Now().Unix()
	rows, err := s.db.QueryContext(r.Context(), `
SELECT id, label, expires_at, used_at, revoked_at, created_at
FROM enrollments
ORDER BY created_at DESC`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "enrollment_list_failed")
		return
	}
	defer rows.Close()

	type enrollment struct {
		ID        string `json:"id"`
		Label     string `json:"label"`
		Status    string `json:"status"`
		CreatedAt int64  `json:"created_at"`
		ExpiresAt int64  `json:"expires_at"`
		UsedAt    *int64 `json:"used_at,omitempty"`
		RevokedAt *int64 `json:"revoked_at,omitempty"`
	}
	out := []enrollment{}
	for rows.Next() {
		var e enrollment
		var label sql.NullString
		var used, revoked sql.NullInt64
		if err := rows.Scan(&e.ID, &label, &e.ExpiresAt, &used, &revoked, &e.CreatedAt); err != nil {
			writeErr(w, http.StatusInternalServerError, "enrollment_scan_failed")
			return
		}
		e.Label = label.String
		e.Status = enrollmentStatus(now, e.ExpiresAt, used, revoked)
		if used.Valid {
			e.UsedAt = &used.Int64
		}
		if revoked.Valid {
			e.RevokedAt = &revoked.Int64
		}
		out = append(out, e)
	}
	writeJSON(w, http.StatusOK, map[string]any{"enrollments": out})
}

func (s *server) handleRevokeEnrollment(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	res, err := s.db.ExecContext(r.Context(),
		`UPDATE enrollments SET revoked_at=? WHERE id=? AND revoked_at IS NULL`,
		time.Now().Unix(), id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "enrollment_revoke_failed")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "enrollment_not_found")
		return
	}
	s.audit(r, "admin_enrollment_revoked", "enrollment_id", id)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleDeleteEnrollment(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	res, err := s.db.ExecContext(r.Context(), `DELETE FROM enrollments WHERE id=?`, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "enrollment_delete_failed")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "enrollment_not_found")
		return
	}
	s.audit(r, "admin_enrollment_deleted", "enrollment_id", id)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleListDevices(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.QueryContext(r.Context(), `
SELECT id, name, status, created_at, updated_at, last_seen_at, approved_at, revoked_at
FROM devices
ORDER BY updated_at DESC`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "device_list_failed")
		return
	}
	defer rows.Close()

	type device struct {
		ID         string `json:"id"`
		Name       string `json:"name"`
		Status     string `json:"status"`
		Online     bool   `json:"online"`
		CreatedAt  int64  `json:"created_at"`
		UpdatedAt  int64  `json:"updated_at"`
		LastSeenAt *int64 `json:"last_seen_at,omitempty"`
		ApprovedAt *int64 `json:"approved_at,omitempty"`
		RevokedAt  *int64 `json:"revoked_at,omitempty"`
	}
	out := []device{}
	for rows.Next() {
		var d device
		var last, approved, revoked sql.NullInt64
		if err := rows.Scan(&d.ID, &d.Name, &d.Status, &d.CreatedAt, &d.UpdatedAt, &last, &approved, &revoked); err != nil {
			writeErr(w, http.StatusInternalServerError, "device_scan_failed")
			return
		}
		if last.Valid {
			d.LastSeenAt = &last.Int64
		}
		if approved.Valid {
			d.ApprovedAt = &approved.Int64
		}
		if revoked.Valid {
			d.RevokedAt = &revoked.Int64
		}
		d.Online = s.isDeviceOnline(d.ID)
		out = append(out, d)
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": out})
}

func (s *server) handleApproveDevice(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	deviceSecretID, deviceSecret, err := newTokenPair("dev")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "token_generation_failed")
		return
	}
	now := time.Now().Unix()
	res, err := s.db.ExecContext(r.Context(),
		`UPDATE devices SET status='approved', device_secret_hash=?, updated_at=?, approved_at=?, revoked_at=NULL WHERE id=? AND status='pending'`,
		hashToken(deviceSecretID+"."+deviceSecret), now, now, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "device_approve_failed")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "pending_device_not_found")
		return
	}
	s.audit(r, "admin_device_approved", "device_id", id)
	s.sendDeviceControl(id, map[string]any{"type": "approved", "device_secret": deviceSecretID + "." + deviceSecret})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleRevokeDevice(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	now := time.Now().Unix()
	_, err := s.db.ExecContext(r.Context(),
		`UPDATE devices SET status='revoked', updated_at=?, revoked_at=? WHERE id=?`,
		now, now, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "device_revoke_failed")
		return
	}
	s.audit(r, "admin_device_revoked", "device_id", id)
	s.closeDevice(id, websocket.StatusPolicyViolation, "device revoked")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleDeleteDevice(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	res, err := s.db.ExecContext(r.Context(), `DELETE FROM devices WHERE id=?`, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "device_delete_failed")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "device_not_found")
		return
	}
	s.audit(r, "admin_device_deleted", "device_id", id)
	s.closeDevice(id, websocket.StatusPolicyViolation, "device deleted")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
