package relay

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func TestAdminSessionManagement(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	sessionA := ts.login(t)
	sessionB := ts.login(t)

	list := ts.listSessions(t, sessionA)
	if len(list.Sessions) != 2 {
		t.Fatalf("session count = %d, want 2", len(list.Sessions))
	}
	if !hasCurrentSession(list.Sessions, sessionA.id) {
		t.Fatalf("current session %q not marked current: %#v", sessionA.id, list.Sessions)
	}

	ts.post(t, sessionA.cookie, "/api/admin/sessions/"+sessionB.id+"/revoke", http.StatusOK)
	ts.get(t, sessionB.cookie, "/api/admin/sessions", http.StatusUnauthorized)

	sessionB = ts.login(t)
	ts.post(t, sessionA.cookie, "/api/admin/sessions/revoke-others", http.StatusOK)
	ts.get(t, sessionA.cookie, "/api/admin/sessions", http.StatusOK)
	ts.get(t, sessionB.cookie, "/api/admin/sessions", http.StatusUnauthorized)

	sessionB = ts.login(t)
	resp := ts.post(t, sessionA.cookie, "/api/admin/sessions/revoke-all", http.StatusOK)
	if !clearsSessionCookie(resp) {
		t.Fatal("revoke-all did not clear current session cookie")
	}
	ts.get(t, sessionA.cookie, "/api/admin/sessions", http.StatusUnauthorized)
	ts.get(t, sessionB.cookie, "/api/admin/sessions", http.StatusUnauthorized)
}

type adminSessionTestServer struct {
	*httptest.Server
	client *http.Client
}

type testSession struct {
	id     string
	cookie *http.Cookie
}

type sessionListResponse struct {
	Sessions []struct {
		ID         string `json:"id"`
		Current    bool   `json:"current"`
		ExpiresAt  int64  `json:"expires_at"`
		CreatedAt  int64  `json:"created_at"`
		LastSeenAt int64  `json:"last_seen_at"`
	} `json:"sessions"`
}

func newAdminSessionTestServer(t *testing.T) adminSessionTestServer {
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
	return adminSessionTestServer{Server: httpServer, client: httpServer.Client()}
}

func (ts adminSessionTestServer) login(t *testing.T) testSession {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, ts.URL+"/api/admin/login", bytes.NewBufferString(`{"secret":"admin-secret-0123456789abcdef"}`))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("login status = %d, want %d", resp.StatusCode, http.StatusOK)
	}
	for _, cookie := range resp.Cookies() {
		if cookie.Name == "rctl_session" {
			id, _, ok := strings.Cut(cookie.Value, ".")
			if !ok || id == "" {
				t.Fatalf("bad session cookie value %q", cookie.Value)
			}
			return testSession{id: id, cookie: cookie}
		}
	}
	t.Fatal("login response missing rctl_session cookie")
	return testSession{}
}

func (ts adminSessionTestServer) listSessions(t *testing.T, session testSession) sessionListResponse {
	t.Helper()
	resp := ts.get(t, session.cookie, "/api/admin/sessions", http.StatusOK)
	defer resp.Body.Close()
	var out sessionListResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	return out
}

func (ts adminSessionTestServer) get(t *testing.T, cookie *http.Cookie, path string, wantStatus int) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, ts.URL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.AddCookie(cookie)
	resp, err := ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != wantStatus {
		defer resp.Body.Close()
		t.Fatalf("GET %s status = %d, want %d", path, resp.StatusCode, wantStatus)
	}
	return resp
}

func (ts adminSessionTestServer) post(t *testing.T, cookie *http.Cookie, path string, wantStatus int) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, ts.URL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.AddCookie(cookie)
	resp, err := ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != wantStatus {
		defer resp.Body.Close()
		t.Fatalf("POST %s status = %d, want %d", path, resp.StatusCode, wantStatus)
	}
	return resp
}

func hasCurrentSession(sessions []struct {
	ID         string `json:"id"`
	Current    bool   `json:"current"`
	ExpiresAt  int64  `json:"expires_at"`
	CreatedAt  int64  `json:"created_at"`
	LastSeenAt int64  `json:"last_seen_at"`
}, id string) bool {
	for _, session := range sessions {
		if session.ID == id && session.Current {
			return true
		}
	}
	return false
}

func clearsSessionCookie(resp *http.Response) bool {
	defer resp.Body.Close()
	for _, cookie := range resp.Cookies() {
		if cookie.Name == "rctl_session" && cookie.MaxAge < 0 {
			return true
		}
	}
	return false
}
