package relay

import (
	"crypto/subtle"
	"database/sql"
	"net/http"
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

func (s *server) handleAdminPage(w http.ResponseWriter, r *http.Request) {
	writeText(w, http.StatusOK, "text/html; charset=utf-8", adminHTML)
}

func (s *server) handleAdminCSS(w http.ResponseWriter, r *http.Request) {
	writeText(w, http.StatusOK, "text/css; charset=utf-8", adminCSS)
}

func (s *server) handleAdminJS(w http.ResponseWriter, r *http.Request) {
	writeText(w, http.StatusOK, "application/javascript; charset=utf-8", adminJS)
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
	_, err = s.db.ExecContext(r.Context(),
		`INSERT INTO sessions(id, secret_hash, expires_at, created_at, last_seen_at) VALUES(?,?,?,?,?)`,
		sessionID, hmacToken(s.cfg.SessionSecret, sessionSecret), now.Add(s.cfg.SessionLifetime).Unix(), now.Unix(), now.Unix())
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
SELECT id, expires_at, created_at, last_seen_at
FROM sessions
WHERE expires_at>=?
ORDER BY last_seen_at DESC`, now)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "session_list_failed")
		return
	}
	defer rows.Close()

	type session struct {
		ID         string `json:"id"`
		Current    bool   `json:"current"`
		ExpiresAt  int64  `json:"expires_at"`
		CreatedAt  int64  `json:"created_at"`
		LastSeenAt int64  `json:"last_seen_at"`
	}
	out := []session{}
	for rows.Next() {
		var item session
		if err := rows.Scan(&item.ID, &item.ExpiresAt, &item.CreatedAt, &item.LastSeenAt); err != nil {
			writeErr(w, http.StatusInternalServerError, "session_scan_failed")
			return
		}
		item.Current = item.ID == currentID
		out = append(out, item)
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": out})
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

func (s *server) handleCreateEnrollment(w http.ResponseWriter, r *http.Request) {
	tokenID, tokenSecret, err := newTokenPair("enroll")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "token_generation_failed")
		return
	}
	now := time.Now()
	token := tokenID + "." + tokenSecret
	_, err = s.db.ExecContext(r.Context(),
		`INSERT INTO enrollments(id, token_hash, expires_at, created_at) VALUES(?,?,?,?)`,
		tokenID, hashToken(token), now.Add(s.cfg.TokenTTL).Unix(), now.Unix())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "enrollment_create_failed")
		return
	}
	s.audit(r, "admin_enrollment_created", "enrollment_id", tokenID, "expires_at", now.Add(s.cfg.TokenTTL).UTC().Format(time.RFC3339))
	writeJSON(w, http.StatusCreated, map[string]any{
		"token":      token,
		"expires_at": now.Add(s.cfg.TokenTTL).UTC().Format(time.RFC3339),
		"relay_url":  s.deviceWebSocketURL(),
	})
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
