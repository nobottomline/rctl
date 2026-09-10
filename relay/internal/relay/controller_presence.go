package relay

import (
	"database/sql"
	"net/http"
	"time"
)

const controllerPresenceTTL = 90 * time.Second

// Authorization, foreground presence and open signaling sessions are separate
// facts. Legacy clients without a heartbeat must not be called offline.
func controllerPresence(status string, heartbeat sql.NullInt64, now time.Time) string {
	if status != "active" {
		return "offline"
	}
	if !heartbeat.Valid {
		return "unknown"
	}
	age := now.Sub(time.Unix(heartbeat.Int64, 0))
	if age >= 0 && age < controllerPresenceTTL {
		return "online"
	}
	return "offline"
}

func (s *server) handleControllerPresence(w http.ResponseWriter, r *http.Request) {
	principal, ok := controllerFromContext(r.Context())
	if !ok {
		writeErr(w, http.StatusUnauthorized, "controller_unauthorized")
		return
	}
	now := time.Now()
	if allowed, _ := s.limiter.allow("controller-heartbeat:"+principal.ControllerID,
		rateLimitConfig{Max: 6, Window: time.Minute}, now); !allowed {
		w.Header().Set("Retry-After", "30")
		writeErr(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	// Re-check authorization in the write: revoke may race the request proof.
	res, err := s.db.ExecContext(r.Context(), `UPDATE controllers SET heartbeat_at=? WHERE id=? AND status='active'`, now.Unix(), principal.ControllerID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "presence_failed")
		return
	}
	if count, _ := res.RowsAffected(); count != 1 {
		writeErr(w, http.StatusUnauthorized, "controller_unauthorized")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "expires_in": int(controllerPresenceTTL.Seconds())})
}
