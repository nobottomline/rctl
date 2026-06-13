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
	s := &server{cfg: config{TrustProxyHeaders: true}}
	r := &http.Request{
		RemoteAddr: "127.0.0.1:12345",
		Header: http.Header{
			"X-Forwarded-For": []string{"198.51.100.1, 127.0.0.1"},
			"X-Real-Ip":       []string{"198.51.100.2"},
		},
	}

	if got := s.clientIP(r); got != "198.51.100.1" {
		t.Fatalf("clientIP = %q, want trusted forwarded value", got)
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
