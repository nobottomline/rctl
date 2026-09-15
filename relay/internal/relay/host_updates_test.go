package relay

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestHostUpdateAdminBoundary(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	socket := filepath.Join(t.TempDir(), "updater.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	var calls atomic.Int32
	updater := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+ts.relay.cfg.AdminSecret {
			t.Error("relay did not authenticate to the host worker")
			w.WriteHeader(http.StatusForbidden)
			return
		}
		calls.Add(1)
		_ = json.NewEncoder(w).Encode(map[string]string{"phase": "idle"})
	})}
	go func() { _ = updater.Serve(listener) }()
	t.Cleanup(func() { _ = updater.Shutdown(context.Background()); _ = listener.Close() })
	ts.relay.cfg.HostUpdateSocket = socket
	session := ts.login(t)
	for _, tc := range []struct {
		path, origin, content string
		auth                  bool
		code                  int
	}{
		{"check", "", "application/json", false, 401},
		{"install", "https://untrusted.invalid", "application/json", true, 403},
		{"policy", "", "text/plain", true, 403},
		{"shell", "", "application/json", true, 405},
		{"check", ts.URL, "application/json", true, 200},
	} {
		req, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/admin/updates/"+tc.path, strings.NewReader(`{}`))
		if tc.auth {
			req.AddCookie(session.cookie)
		}
		req.Header.Set("Origin", tc.origin)
		req.Header.Set("Content-Type", tc.content)
		resp, err := ts.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != tc.code {
			t.Fatalf("%+v: %d", tc, resp.StatusCode)
		}
	}
	if calls.Load() != 1 {
		t.Fatal("unauthorized request reached privileged worker", calls.Load())
	}
	resp := ts.get(t, session.cookie, "/api/admin/updates", 200)
	resp.Body.Close()
}
