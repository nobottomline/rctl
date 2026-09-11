package relay

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

// auditLogCap bounds the audit_log table; older rows are pruned past this. Kept
// generous so history survives — 20k rows is months of events yet still a few MB
// of SQLite, and the UI virtualizes the list so render cost is independent of it.
const auditLogCap = 20000

// auditActor is the "who" of an audit row, captured at write time. Admin actors
// carry the browser fingerprint the admin SPA sends on every request so the feed
// can label them after the session is gone; controller actors carry the name the
// controller had at that moment so deleting it from history keeps the label.
type auditActor struct {
	Kind  string // admin | controller | device | system
	ID    string
	Label string
	UA    string
	Hints string
	Touch any // int or nil
}

func (s *server) audit(r *http.Request, event string, args ...any) {
	s.auditAs(r, s.actorFor(r, args), event, args...)
}

// auditAs records an event on behalf of an explicit actor. Handlers that know the
// principal before the request context does (pairing claim) use it directly.
func (s *server) auditAs(r *http.Request, actor auditActor, event string, args ...any) {
	ip := s.clientIP(r)
	sessionID, _, _ := parseSessionCookie(r) // empty for device/system events (no admin cookie)
	if s.log != nil {
		fields := []any{
			"event", event,
			"remote", ip,
			"method", r.Method,
			"path", r.URL.Path,
		}
		if actor.Kind != "" {
			fields = append(fields, "actor_kind", actor.Kind, "actor_id", actor.ID)
		}
		fields = append(fields, args...)
		s.log.Info("audit", fields...)
	}
	s.persistAudit(event, ip, sessionID, r.Method, r.URL.Path, actor, args...)
}

// actorFor resolves the acting principal: an admin session cookie wins, then an
// authenticated controller, then explicit ids in the event fields (a controller
// finishing a pairing claim, a device on its own socket).
func (s *server) actorFor(r *http.Request, args []any) auditActor {
	if sessionID, _, ok := parseSessionCookie(r); ok {
		return adminActor(r, sessionID)
	}
	if principal, ok := controllerFromContext(r.Context()); ok {
		return auditActor{Kind: "controller", ID: principal.ControllerID, Label: principal.Name}
	}
	fields := make(map[string]any, len(args)/2)
	for i := 0; i+1 < len(args); i += 2 {
		if key, ok := args[i].(string); ok {
			fields[key] = args[i+1]
		}
	}
	// Login has no cookie yet; the handler names the session it just created.
	if id, ok := fields["session_id"].(string); ok && strings.HasPrefix(id, "sess_") {
		return adminActor(r, id)
	}
	if id, ok := fields["controller_id"].(string); ok && id != "" {
		label, _ := fields["controller_name"].(string)
		return auditActor{Kind: "controller", ID: id, Label: label}
	}
	if id, ok := fields["device_id"].(string); ok && id != "" {
		return auditActor{Kind: "device", ID: id}
	}
	return auditActor{}
}

func adminActor(r *http.Request, sessionID string) auditActor {
	ua := r.UserAgent()
	if len(ua) > 200 {
		ua = ua[:200]
	}
	hints := r.Header.Get("Sec-Ch-Ua")
	if len(hints) > 256 {
		hints = hints[:256]
	}
	return auditActor{Kind: "admin", ID: sessionID, UA: ua, Hints: hints, Touch: touchHeader(r)}
}

// persistAudit records the event in the audit_log table so the admin UI can show
// an activity history. Best-effort: a failure here must never break a handler.
func (s *server) persistAudit(event, ip, sessionID, method, path string, actor auditActor, args ...any) {
	if s.db == nil {
		return
	}
	detail := ""
	if len(args) > 1 {
		kv := make(map[string]any, len(args)/2)
		for i := 0; i+1 < len(args); i += 2 {
			if key, ok := args[i].(string); ok {
				kv[key] = args[i+1]
			}
		}
		if len(kv) > 0 {
			if b, err := json.Marshal(kv); err == nil {
				detail = string(b)
			}
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if _, err := s.db.ExecContext(ctx, `
INSERT INTO audit_log (ts, event, ip, session_id, method, path, detail, actor_kind, actor_id, actor_label, actor_ua, actor_hints, actor_touch)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		time.Now().Unix(), event, ip, sessionID, method, path, detail,
		nullIfEmpty(actor.Kind), nullIfEmpty(actor.ID), nullIfEmpty(actor.Label),
		nullIfEmpty(actor.UA), nullIfEmpty(actor.Hints), actor.Touch); err != nil {
		if s.log != nil {
			s.log.Warn("audit persist failed", "error", err)
		}
		return
	}
	// Keep the table bounded (no-op until it grows past the cap).
	_, _ = s.db.ExecContext(ctx,
		`DELETE FROM audit_log WHERE id <= (SELECT MAX(id) FROM audit_log) - ?`, auditLogCap)
}

// auditSystem records an event the relay performed on its own (retention, startup
// housekeeping): no request, no session, actor "system".
func (s *server) auditSystem(event string, args ...any) {
	if s.log != nil {
		s.log.Info("audit", append([]any{"event", event, "actor_kind", "system"}, args...)...)
	}
	s.persistAudit(event, "", "", "", "", auditActor{Kind: "system", ID: "relay"}, args...)
}

func nullIfEmpty(v string) any {
	if v == "" {
		return nil
	}
	return v
}
