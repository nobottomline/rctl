package relay

import (
	"net/http"
	"runtime"
	"time"
)

// handleStatus reports relay build/runtime info and live counts for the admin
// dashboard's status panel.
func (s *server) handleStatus(w http.ResponseWriter, r *http.Request) {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)

	s.mu.RLock()
	online := len(s.devices)
	s.mu.RUnlock()

	now := time.Now().Unix()
	var devicesTotal, devicesPending, sessions int
	_ = s.db.QueryRowContext(r.Context(), `SELECT count(*) FROM devices`).Scan(&devicesTotal)
	_ = s.db.QueryRowContext(r.Context(), `SELECT count(*) FROM devices WHERE status='pending'`).Scan(&devicesPending)
	_ = s.db.QueryRowContext(r.Context(), `SELECT count(*) FROM sessions WHERE expires_at>=?`, now).Scan(&sessions)

	writeJSON(w, http.StatusOK, map[string]any{
		"version":                  Version,
		"protocol_major":           protocolMajor,
		"protocol_minor":           protocolMinor,
		"features":                 s.features(),
		"update_configured":        s.cfg.UpdateManifestURL != "",
		"device_package_available": len(s.publicPackage) != 0,
		"device_package_version":   s.publicPackageInfo.Version,
		"go_version":               runtime.Version(),
		"started_at":               s.startedAt.Unix(),
		"uptime_seconds":           int64(time.Since(s.startedAt).Seconds()),
		"devices_total":            devicesTotal,
		"devices_online":           online,
		"devices_pending":          devicesPending,
		"sessions":                 sessions,
		"goroutines":               runtime.NumGoroutine(),
		"mem_alloc_bytes":          m.Alloc,
		"mem_sys_bytes":            m.Sys,
	})
}
