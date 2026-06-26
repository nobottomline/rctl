package relay

import (
	"net/http"
	"testing"
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
