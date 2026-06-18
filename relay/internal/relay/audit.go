package relay

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

// auditLogCap bounds the audit_log table; older rows are pruned past this.
const auditLogCap = 2000

func (s *server) audit(r *http.Request, event string, args ...any) {
	ip := s.clientIP(r)
	if s.log != nil {
		fields := []any{
			"event", event,
			"remote", ip,
			"method", r.Method,
			"path", r.URL.Path,
		}
		fields = append(fields, args...)
		s.log.Info("audit", fields...)
	}
	s.persistAudit(event, ip, r.Method, r.URL.Path, args...)
}

// persistAudit records the event in the audit_log table so the admin UI can show
// an activity history. Best-effort: a failure here must never break a handler.
func (s *server) persistAudit(event, ip, method, path string, args ...any) {
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
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO audit_log (ts, event, ip, method, path, detail) VALUES (?, ?, ?, ?, ?, ?)`,
		time.Now().Unix(), event, ip, method, path, detail); err != nil {
		if s.log != nil {
			s.log.Warn("audit persist failed", "error", err)
		}
		return
	}
	// Keep the table bounded (no-op until it grows past the cap).
	_, _ = s.db.ExecContext(ctx,
		`DELETE FROM audit_log WHERE id <= (SELECT MAX(id) FROM audit_log) - ?`, auditLogCap)
}
