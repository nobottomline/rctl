package relay

import (
	"net/http"
	"testing"
	"time"
)

func TestClientIPIgnoresForwardedHeadersByDefault(t *testing.T) {
	s := &server{}
	r := &http.Request{
		RemoteAddr: "203.0.113.10:12345",
		Header: http.Header{
			"X-Forwarded-For": []string{"198.51.100.1"},
			"X-Real-Ip":       []string{"198.51.100.2"},
		},
	}

	if got := s.clientIP(r); got != "203.0.113.10" {
		t.Fatalf("clientIP = %q, want remote peer", got)
	}
}

func TestClientIPUsesForwardedHeadersWhenTrusted(t *testing.T) {
	// One trusted edge proxy (default depth 1): the real client is the RIGHTMOST
	// X-Forwarded-For entry the proxy appended; a leftmost entry the client prepended
	// is ignored, so a client can't forge its source IP.
	s := &server{cfg: config{TrustProxyHeaders: true}}
	r := &http.Request{
		RemoteAddr: "127.0.0.1:12345",
		Header: http.Header{
			"X-Forwarded-For": []string{"203.0.113.9, 198.51.100.1"}, // spoofed, real
			"X-Real-Ip":       []string{"198.51.100.2"},
		},
	}

	if got := s.clientIP(r); got != "198.51.100.1" {
		t.Fatalf("clientIP = %q, want rightmost (trusted) forwarded value", got)
	}
}

func TestClientIPIgnoresSpoofedLeftmostXFF(t *testing.T) {
	s := &server{cfg: config{TrustProxyHeaders: true}}
	r := &http.Request{
		RemoteAddr: "127.0.0.1:12345",
		Header:     http.Header{"X-Forwarded-For": []string{"1.1.1.1, 2.2.2.2, 198.51.100.1"}},
	}

	if got := s.clientIP(r); got != "198.51.100.1" {
		t.Fatalf("clientIP = %q, want rightmost real client, not a spoofed leftmost hop", got)
	}
}

func TestClientIPFailsClosedWhenChainShorterThanDepth(t *testing.T) {
	// Configured for 2 trusted proxies but only 1 hop present -> the request didn't
	// traverse them all (or is forged): fall back to the peer, never onto a spoof.
	s := &server{cfg: config{TrustProxyHeaders: true, TrustedProxyDepth: 2}}
	r := &http.Request{
		RemoteAddr: "127.0.0.1:12345",
		Header:     http.Header{"X-Forwarded-For": []string{"198.51.100.1"}},
	}

	if got := s.clientIP(r); got != "127.0.0.1" {
		t.Fatalf("clientIP = %q, want RemoteAddr fallback (fail closed)", got)
	}
}

func TestClientIPFallsBackToXRealIPWhenTrusted(t *testing.T) {
	s := &server{cfg: config{TrustProxyHeaders: true}}
	r := &http.Request{
		RemoteAddr: "127.0.0.1:12345",
		Header: http.Header{
			"X-Real-Ip": []string{"198.51.100.2"},
		},
	}

	if got := s.clientIP(r); got != "198.51.100.2" {
		t.Fatalf("clientIP = %q, want X-Real-IP", got)
	}
}

// Excess requests are rejected with the remaining window, and admission
// resumes once the window passes.
func TestRateLimitRejectsBeyondMaxAndResets(t *testing.T) {
	l := newRateLimiter(5 * time.Minute)
	cfg := rateLimitConfig{Max: 2, Window: time.Minute}
	now := time.Unix(1000, 0)

	for i := 0; i < 2; i++ {
		if allowed, _ := l.allow("ip:203.0.113.1", cfg, now); !allowed {
			t.Fatalf("request %d was rejected below the max", i+1)
		}
	}
	allowed, retryAfter := l.allow("ip:203.0.113.1", cfg, now)
	if allowed || retryAfter != time.Minute {
		t.Fatalf("excess request = allowed %v retryAfter %v", allowed, retryAfter)
	}
	allowed, _ = l.allow("ip:203.0.113.2", cfg, now) // a different key is unaffected
	if !allowed {
		t.Fatal("an unrelated key was rejected with another key's budget")
	}
	if allowed, _ := l.allow("ip:203.0.113.1", cfg, now.Add(2*time.Minute)); !allowed {
		t.Fatal("admission did not resume after the window passed")
	}
}

// A key's budget never outlives its ttl even when sweeps are amortized:
// windows longer than the ttl must not stay throttled between sweeps. The
// sweep runs on another key exactly at the ttl boundary (strict `>`, so the
// entry survives it), and the throttled key is only re-admitted through the
// per-key stale check — not by a sweep deleting its entry.
func TestRateLimitKeyBudgetExpiresWithTTL(t *testing.T) {
	l := newRateLimiter(5 * time.Minute)
	cfg := rateLimitConfig{Max: 1, Window: 10 * time.Minute} // window longer than ttl
	t0 := time.Unix(1000, 0)

	if allowed, _ := l.allow("ip:203.0.113.1", cfg, t0); !allowed {
		t.Fatal("first request was rejected below the max")
	}
	if allowed, _ := l.allow("ip:203.0.113.1", cfg, t0); allowed {
		t.Fatal("excess request within the window was allowed")
	}
	// A sweep on another key at exactly the ttl must keep the entry (the
	// expiry comparison is strict), leaving the key throttled.
	if allowed, _ := l.allow("ip:203.0.113.2", cfg, t0.Add(5*time.Minute)); !allowed {
		t.Fatal("sweep call was rejected below the max")
	}
	if got := l.entries["ip:203.0.113.1"]; got.Count != 2 {
		t.Fatalf("swept or recreated the throttled entry at the ttl boundary: %+v", got)
	}
	// Past the ttl by the smallest step, with no sweep in between (the sweep
	// interval just reset), the key's own budget must reset.
	if allowed, _ := l.allow("ip:203.0.113.1", cfg, t0.Add(5*time.Minute+time.Nanosecond)); !allowed {
		t.Fatal("key stayed throttled after its ttl expired")
	}
}

// The sweep must not run on every request: entries that expired between two
// calls inside one sweep interval survive until the interval passes.
func TestRateLimitSweepIsAmortized(t *testing.T) {
	l := newRateLimiter(30 * time.Second)
	cfg := rateLimitConfig{Max: 10, Window: time.Minute}
	t0 := time.Unix(1000, 0)

	// The first allow anchors the sweep clock.
	if allowed, _ := l.allow("ip:203.0.113.1", cfg, t0); !allowed {
		t.Fatal("first request was rejected below the max")
	}
	// An entry that is already TTL-expired is seeded directly; the next call
	// inside the quarter-TTL sweep interval must not sweep it away.
	l.entries["ip:203.0.113.9"] = rateEntry{
		Count:     1,
		ResetAt:   t0.Add(time.Minute),
		UpdatedAt: t0.Add(-40 * time.Second),
	}
	// A seeded live entry (fresh UpdatedAt) must survive a sweep unchanged:
	// asserting on a key the sweeping call itself re-creates would pass even
	// if the sweep deleted and recreated it.
	l.entries["ip:203.0.113.8"] = rateEntry{
		Count:     3,
		ResetAt:   t0.Add(time.Minute),
		UpdatedAt: t0.Add(-5 * time.Second),
	}
	if allowed, _ := l.allow("ip:203.0.113.2", cfg, t0.Add(5*time.Second)); !allowed {
		t.Fatal("second request was rejected below the max")
	}
	if _, ok := l.entries["ip:203.0.113.9"]; !ok {
		t.Fatal("entry was swept before the amortized interval")
	}
	// Crossing the sweep interval retires the stale entry and keeps live ones.
	if allowed, _ := l.allow("ip:203.0.113.2", cfg, t0.Add(10*time.Second)); !allowed {
		t.Fatal("third request was rejected below the max")
	}
	if _, ok := l.entries["ip:203.0.113.9"]; ok {
		t.Fatal("stale entry survived a sweep")
	}
	if got := l.entries["ip:203.0.113.8"]; got.Count != 3 {
		t.Fatalf("live seeded entry did not survive the sweep: %+v", got)
	}
}
