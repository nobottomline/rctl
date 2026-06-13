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
	var expiresAt int64
	err := s.db.QueryRowContext(r.Context(), `SELECT secret_hash, expires_at FROM sessions WHERE id=?`, sessionID).Scan(&secretHash, &expiresAt)
	if err != nil || expiresAt < now {
		return false
	}
	if subtle.ConstantTimeCompare([]byte(secretHash), []byte(hashToken(secret))) != 1 {
		return false
	}
	_, _ = s.db.ExecContext(r.Context(), `UPDATE sessions SET last_seen_at=? WHERE id=?`, now, sessionID)
	return true
}

func (s *server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; connect-src 'self' ws: wss:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
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
