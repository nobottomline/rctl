package main

import (
	"net"
	"net/http"
	"testing"
)

func TestHealthcheck(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/healthz" {
			http.NotFound(w, r)
			return
		}
		w.WriteHeader(http.StatusOK)
	})}
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	if err := healthcheck("http://" + listener.Addr().String() + "/healthz"); err != nil {
		t.Fatal(err)
	}
	if err := healthcheck("http://" + listener.Addr().String() + "/missing"); err == nil {
		t.Fatal("expected non-200 failure")
	}
	for _, raw := range []string{"https://127.0.0.1/healthz", "http://localhost/healthz", "http://example.com/healthz", "http://user:pass@127.0.0.1/healthz"} {
		if err := healthcheck(raw); err == nil {
			t.Errorf("accepted unsafe healthcheck URL %q", raw)
		}
	}
}
