package relay

import (
	"context"
	"database/sql"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func TestControlPageRequiresApprovedDevice(t *testing.T) {
	ts := newControlPageTestServer(t)

	req, err := http.NewRequest(http.MethodGet, ts.URL+"/control/devices/pending-ipad", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.AddCookie(ts.sessionCookie)
	resp, err := ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusForbidden)
	}
}

func TestControlPageRequiresAdminSession(t *testing.T) {
	ts := newControlPageTestServer(t)

	resp, err := ts.client.Get(ts.URL + "/control/devices/approved-ipad")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusUnauthorized)
	}
}

func TestControlPageRequiresOnlineDevice(t *testing.T) {
	ts := newControlPageTestServer(t)

	req, err := http.NewRequest(http.MethodGet, ts.URL+"/control/devices/offline-ipad", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.AddCookie(ts.sessionCookie)
	resp, err := ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	got := readResponseBody(t, resp)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d, want %d: %s", resp.StatusCode, http.StatusNotFound, got)
	}
	if !strings.Contains(got, "device_offline") {
		t.Fatalf("response missing device_offline: %s", got)
	}
}

func TestControlPageInjectsRelayPaths(t *testing.T) {
	ts := newControlPageTestServer(t)

	req, err := http.NewRequest(http.MethodGet, ts.URL+"/control/devices/approved-ipad", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.AddCookie(ts.sessionCookie)
	resp, err := ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	got := readResponseBody(t, resp)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want %d: %s", resp.StatusCode, http.StatusOK, got)
	}
	for _, want := range []string{
		`window.RCTL_PROXY_BASE="/proxy/devices/approved-ipad";`,
		`window.RCTL_STREAM_BASE="/stream/devices/approved-ipad";`,
		`window.RCTL_TERM_WS_BASE="/term/devices/approved-ipad";`,
		`window.RCTL_RELAY_DEVICE_ID="approved-ipad";`,
		`fetch('/v1/info')`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("response missing %q:\n%s", want, got)
		}
	}
	csp := resp.Header.Get("Content-Security-Policy")
	if !strings.Contains(csp, "script-src 'self' 'unsafe-inline'") {
		t.Fatalf("control CSP does not allow current inline client script: %q", csp)
	}
}

type controlPageTestServer struct {
	*httptest.Server
	client        *http.Client
	sessionCookie *http.Cookie
}

func newControlPageTestServer(t *testing.T) controlPageTestServer {
	t.Helper()

	webDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(webDir, "index.html"), []byte(`<html><head></head><body><script>fetch('/v1/info')</script></body></html>`), 0o644); err != nil {
		t.Fatal(err)
	}

	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })

	s := &server{
		cfg:     config{WebDir: webDir},
		db:      db,
		devices: make(map[string]*deviceConn),
		limiter: newRateLimiter(5 * time.Minute),
	}
	if err := s.migrate(context.Background()); err != nil {
		t.Fatal(err)
	}

	now := time.Now().Unix()
	for id, status := range map[string]string{
		"approved-ipad": "approved",
		"offline-ipad":  "approved",
		"pending-ipad":  "pending",
	} {
		if _, err := db.ExecContext(context.Background(),
			`INSERT INTO devices(id, name, status, created_at, updated_at) VALUES(?, ?, ?, ?, ?)`,
			id, id, status, now, now,
		); err != nil {
			t.Fatal(err)
		}
	}
	s.devices["approved-ipad"] = &deviceConn{id: "approved-ipad"}

	sessionID := "test-session"
	sessionSecret := "test-secret"
	if _, err := db.ExecContext(context.Background(),
		`INSERT INTO sessions(id, secret_hash, expires_at, created_at, last_seen_at) VALUES(?, ?, ?, ?, ?)`,
		sessionID, hmacToken(s.cfg.SessionSecret, sessionSecret), now+3600, now, now,
	); err != nil {
		t.Fatal(err)
	}

	mux := http.NewServeMux()
	s.routes(mux)
	httpServer := httptest.NewServer(s.securityHeaders(mux))
	t.Cleanup(httpServer.Close)

	return controlPageTestServer{
		Server: httpServer,
		client: httpServer.Client(),
		sessionCookie: &http.Cookie{
			Name:  "rctl_session",
			Value: sessionID + "." + sessionSecret,
		},
	}
}

func readResponseBody(t *testing.T, resp *http.Response) string {
	t.Helper()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}
