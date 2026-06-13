package relay

import (
	"bytes"
	"context"
	"database/sql"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func TestAuditLogsAdminLoginWithoutSecrets(t *testing.T) {
	var logs bytes.Buffer
	ts := newAuditTestServer(t, &logs)

	postJSON(t, ts.client, ts.URL+"/api/admin/login", `{"secret":"wrong-secret"}`)
	postJSON(t, ts.client, ts.URL+"/api/admin/login", `{"secret":"admin-secret-0123456789abcdef"}`)

	got := logs.String()
	for _, want := range []string{
		"admin_login_failed",
		"admin_login_succeeded",
		"invalid_secret",
		"session_id",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("audit log missing %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "admin-secret-0123456789abcdef") || strings.Contains(got, "wrong-secret") {
		t.Fatalf("audit log leaked secret:\n%s", got)
	}
}

type auditTestServer struct {
	*httptest.Server
	client *http.Client
}

func newAuditTestServer(t *testing.T, logs *bytes.Buffer) auditTestServer {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })

	s := &server{
		cfg: config{
			AdminSecret:     "admin-secret-0123456789abcdef",
			SessionLifetime: 24 * time.Hour,
		},
		db:      db,
		log:     slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelInfo})),
		devices: make(map[string]*deviceConn),
		limiter: newRateLimiter(5 * time.Minute),
	}
	if err := s.migrate(context.Background()); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	s.routes(mux)
	httpServer := httptest.NewServer(s.securityHeaders(mux))
	t.Cleanup(httpServer.Close)
	return auditTestServer{Server: httpServer, client: httpServer.Client()}
}

func postJSON(t *testing.T, client *http.Client, url string, body string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, url, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	return resp
}
