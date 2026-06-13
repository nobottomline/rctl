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
		allowed, retryAfter := s.limiter.allow(name+":"+clientIP(r), cfg, time.Now())
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

func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		for i := len(parts) - 1; i >= 0; i-- {
			ip := strings.TrimSpace(parts[i])
			if net.ParseIP(ip) != nil {
				return ip
			}
		}
	}
	if xrip := strings.TrimSpace(r.Header.Get("X-Real-IP")); net.ParseIP(xrip) != nil {
		return xrip
	}
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
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
