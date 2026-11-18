package relay

import (
	"crypto/subtle"
	"net/http"
	"strings"
	"time"
)

func (s *server) withAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.validSession(r) {
			writeErr(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next(w, r)
	}
}

// withAdminOrigin rejects browser-borne cross-site and sibling-origin requests
// on admin-authenticated routes. SameSite=Strict cookies still ride along when
// a related subdomain drives a form, fetch, or WebSocket handshake against the
// relay, so any Origin a browser supplies must equal PublicURL. API clients
// that send no Origin (curl, the setup wizard) are unaffected. Mutating device
// GETs through the tunnels are additionally guarded by withTunnelOrigin,
// because a no-cors cross-site GET carries neither header.
func (s *server) withAdminOrigin(next http.HandlerFunc) http.HandlerFunc {
	return s.guardOrigin(false, next)
}

func (s *server) withTunnelOrigin(next http.HandlerFunc) http.HandlerFunc {
	return s.guardOrigin(true, next)
}

// guardOrigin rejects browser-borne cross-site and sibling-origin requests.
// Mutating device GETs through the tunnels are reachable by a no-cors fetch
// that sends no Origin header — only Fetch Metadata marks it as not
// same-origin — so tunnel routes run in strict mode, which also rejects
// "Sec-Fetch-Site: same-site". Browsers without Fetch Metadata (pre-16.4
// Safari) keep working for same-origin use but stay outside this check; that
// residual risk is accepted because such browsers cannot be distinguished
// from the Origin-less API clients the setup wizard and release scripts need.
func (s *server) guardOrigin(strict bool, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		site := r.Header.Get("Sec-Fetch-Site")
		if site == "cross-site" || (strict && site == "same-site") {
			writeErr(w, http.StatusForbidden, "origin_rejected")
			return
		}
		if !s.requestOriginAllowed(r) {
			writeErr(w, http.StatusForbidden, "origin_rejected")
			return
		}
		next(w, r)
	}
}

// requestOriginAllowed reports whether an Origin-bearing browser request
// matches the configured public origin. An absent header means a non-browser
// client; an explicit empty value or a repeated header is not a state any
// browser produces and fails closed. The canonical form of the configured URL
// is accepted alongside its literal value, so a "https://rctl.example.com:443"
// deployment matches the port-less Origin browsers send even when the server
// was built without loadConfig.
func (s *server) requestOriginAllowed(r *http.Request) bool {
	origins := r.Header.Values("Origin")
	switch {
	case len(origins) > 1:
		return false
	case len(origins) == 1:
		if origins[0] == "" {
			return false
		}
		expected := strings.TrimSuffix(s.cfg.PublicURL, "/")
		return origins[0] == expected || origins[0] == canonicalPublicURL(expected)
	default:
		return true
	}
}

// adminWrite wraps a state-changing admin route with the same-origin CSRF
// check, the admin session check, and the admin rate limit.
func (s *server) adminWrite(next http.HandlerFunc) http.HandlerFunc {
	return s.withAdminOrigin(s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, next)))
}

// adminTunnel wraps an admin-authenticated tunneling route (HTTP proxy, media
// stream, terminal, signal, or client WebSocket) with the strict CSRF origin
// check, the admin session check, and the tunnel rate limit.
func (s *server) adminTunnel(next http.HandlerFunc) http.HandlerFunc {
	return s.withTunnelOrigin(s.withAdmin(s.withRateLimit("tunnel", s.cfg.TunnelLimit, next)))
}

func (s *server) validSession(r *http.Request) bool {
	sessionID, secret, ok := parseSessionCookie(r)
	if !ok {
		return false
	}
	return s.validSessionToken(r, sessionID, secret)
}

func parseSessionCookie(r *http.Request) (string, string, bool) {
	c, err := r.Cookie("rctl_session")
	if err != nil {
		return "", "", false
	}
	sessionID, secret, ok := strings.Cut(c.Value, ".")
	if !ok || sessionID == "" || secret == "" {
		return "", "", false
	}
	return sessionID, secret, true
}

func (s *server) validSessionToken(r *http.Request, sessionID, secret string) bool {
	now := time.Now().Unix()
	var secretHash string
	var expiresAt, lastSeen int64
	err := s.db.QueryRowContext(r.Context(), `SELECT secret_hash, expires_at, last_seen_at FROM sessions WHERE id=?`, sessionID).Scan(&secretHash, &expiresAt, &lastSeen)
	if err != nil || expiresAt < now {
		return false
	}
	if subtle.ConstantTimeCompare([]byte(secretHash), []byte(hmacToken(s.cfg.SessionSecret, secret))) != 1 {
		return false
	}
	if now-lastSeen >= 60 { // refresh last_seen at most once a minute, not on every request
		// Backfill Sec-CH-UA client hints and the touch-points signal for sessions
		// created before those columns existed, so detection works without a re-login.
		// COALESCE leaves an already-set value alone; touchHeader is nil when the
		// header is absent, so it never clobbers a stored value.
		hints := r.Header.Get("Sec-Ch-Ua")
		if len(hints) > 256 {
			hints = hints[:256]
		}
		_, _ = s.db.ExecContext(r.Context(),
			`UPDATE sessions SET last_seen_at=?, client_hints=COALESCE(NULLIF(client_hints,''), ?), touch_points=COALESCE(touch_points, ?) WHERE id=?`,
			now, hints, touchHeader(r), sessionID)
	}
	return true
}

func (s *server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		next.ServeHTTP(w, r)
	})
}

func (s *server) requestLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		s.log.Info("request", "method", r.Method, "path", r.URL.Path, "remote", r.RemoteAddr, "duration_ms", time.Since(start).Milliseconds())
	})
}
