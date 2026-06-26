package relay

import (
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

type rateLimitConfig struct {
	Max    int
	Window time.Duration
}

type rateLimiter struct {
	mu      sync.Mutex
	entries map[string]rateEntry
	ttl     time.Duration
}

type rateEntry struct {
	Count     int
	ResetAt   time.Time
	UpdatedAt time.Time
}

func newRateLimiter(ttl time.Duration) *rateLimiter {
	return &rateLimiter{
		entries: make(map[string]rateEntry),
		ttl:     ttl,
	}
}

func loadRateLimit(prefix string, max int, window time.Duration) rateLimitConfig {
	if v := getenvInt(prefix+"_MAX", max); v > 0 {
		max = v
	}
	if v := getenvDuration(prefix+"_WINDOW", window); v > 0 {
		window = v
	}
	return rateLimitConfig{Max: max, Window: window}
}

func (s *server) withRateLimit(name string, cfg rateLimitConfig, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		allowed, retryAfter := s.limiter.allow(name+":"+s.clientIP(r), cfg, time.Now())
		if !allowed {
			w.Header().Set("Retry-After", strconv.Itoa(int(retryAfter.Seconds())+1))
			writeErr(w, http.StatusTooManyRequests, "rate_limited")
			return
		}
		next(w, r)
	}
}

func (l *rateLimiter) allow(key string, cfg rateLimitConfig, now time.Time) (bool, time.Duration) {
	if cfg.Max <= 0 {
		return true, 0
	}
	l.mu.Lock()
	defer l.mu.Unlock()

	l.gcLocked(now)

	entry := l.entries[key]
	if entry.ResetAt.IsZero() || now.After(entry.ResetAt) {
		entry = rateEntry{ResetAt: now.Add(cfg.Window)}
	}
	entry.Count++
	entry.UpdatedAt = now
	l.entries[key] = entry

	if entry.Count > cfg.Max {
		return false, time.Until(entry.ResetAt)
	}
	return true, 0
}

func (l *rateLimiter) gcLocked(now time.Time) {
	for key, entry := range l.entries {
		if now.Sub(entry.UpdatedAt) > l.ttl {
			delete(l.entries, key)
		}
	}
}

func (s *server) clientIP(r *http.Request) string {
	if s.cfg.TrustProxyHeaders {
		if ip := forwardedClientIP(r, s.cfg.TrustedProxyDepth); ip != "" {
			return ip
		}
	}
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
}

// forwardedClientIP resolves the real client IP from the proxy headers. It reads
// X-Forwarded-For from the RIGHT: with `depth` trusted proxies in front, the real
// client is the depth-th entry from the end (the rightmost was appended by our own
// edge proxy and can't be spoofed). Taking the leftmost entry instead — the naive
// reading — lets a client forge its own source IP and bypass the per-IP limiter.
func forwardedClientIP(r *http.Request, depth int) string {
	if depth < 1 {
		depth = 1
	}
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		var ips []string
		for _, part := range strings.Split(xff, ",") {
			ip := strings.TrimSpace(part)
			if net.ParseIP(ip) != nil {
				ips = append(ips, ip)
			}
		}
		// Only trust the chain if it's at least as long as the proxies we expect; a
		// shorter chain means the request didn't traverse them all (or is forged), so
		// fall through to X-Real-IP / RemoteAddr — fail closed, never onto a spoof.
		if len(ips) >= depth {
			return ips[len(ips)-depth]
		}
	}
	if xrip := strings.TrimSpace(r.Header.Get("X-Real-IP")); net.ParseIP(xrip) != nil {
		return xrip
	}
	return ""
}

func getenvInt(key string, fallback int) int {
	v := getenv(key, "")
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return fallback
	}
	return n
}
