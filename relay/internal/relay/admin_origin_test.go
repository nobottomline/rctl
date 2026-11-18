package relay

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Sibling-subdomain origins drive requests with the SameSite=Strict session
// cookie still attached; every browser-borne cross-site request must be
// rejected before it reaches an admin handler, while Origin-less API clients
// (the setup wizard, curl scripts) keep working.
func TestAdminOriginBoundary(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	session := ts.login(t)

	for _, tc := range []struct {
		name, path, origin, fetchSite string
		auth                          bool
		want                          int
	}{
		{"sibling origin on admin post", "/api/admin/sessions/revoke-others", "https://sibling.evil.invalid", "", true, http.StatusForbidden},
		{"null origin on admin post", "/api/admin/sessions/revoke-others", "null", "", true, http.StatusForbidden},
		{"cross-site fetch on admin post", "/api/admin/sessions/revoke-others", ts.URL, "cross-site", true, http.StatusForbidden},
		{"matching origin on admin post", "/api/admin/sessions/revoke-others", ts.URL, "same-origin", true, http.StatusOK},
		{"no origin on admin post", "/api/admin/sessions/revoke-others", "", "", true, http.StatusOK},
		{"unauthenticated post still origin checked", "/api/admin/sessions/revoke-others", "https://sibling.evil.invalid", "", false, http.StatusForbidden},
		{"sibling origin on tunnel ws", "/signal/devices/unknown", "https://sibling.evil.invalid", "", true, http.StatusForbidden},
		{"no origin on tunnel ws", "/signal/devices/unknown", "", "", true, http.StatusNotFound},
		{"matching origin on tunnel ws", "/signal/devices/unknown", ts.URL, "same-origin", true, http.StatusNotFound},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req, err := http.NewRequest(http.MethodPost, ts.URL+tc.path, nil)
			if err != nil {
				t.Fatal(err)
			}
			req.Method = http.MethodPost
			if strings.HasPrefix(tc.path, "/signal/") {
				req.Method = http.MethodGet
			}
			if tc.auth {
				req.AddCookie(session.cookie)
			}
			if tc.origin != "" {
				req.Header.Set("Origin", tc.origin)
			}
			if tc.fetchSite != "" {
				req.Header.Set("Sec-Fetch-Site", tc.fetchSite)
			}
			resp, err := ts.client.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != tc.want {
				t.Fatalf("status = %d, want %d", resp.StatusCode, tc.want)
			}
		})
	}
}

// The device tunnels carry state-changing GET paths, and a sibling page can
// drive those with a no-cors fetch that omits the Origin header entirely;
// Fetch Metadata is the only same-origin evidence such a request carries.
func TestTunnelOriginBoundary(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	session := ts.login(t)

	for _, tc := range []struct {
		name, fetchSite string
		want            int
	}{
		{"sibling no-cors get", "same-site", http.StatusForbidden},
		{"cross-site no-cors get", "cross-site", http.StatusForbidden},
		{"same-origin fetch", "same-origin", http.StatusNotFound},
		{"address-bar navigation", "none", http.StatusNotFound},
		{"non-browser client", "", http.StatusNotFound},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req, err := http.NewRequest(http.MethodGet, ts.URL+"/proxy/devices/unknown/v1/capabilities", nil)
			if err != nil {
				t.Fatal(err)
			}
			req.AddCookie(session.cookie)
			req.Header.Set("Sec-Fetch-Site", tc.fetchSite)
			resp, err := ts.client.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != tc.want {
				t.Fatalf("status = %d, want %d", resp.StatusCode, tc.want)
			}
		})
	}
}

// Browsers omit the default port from the Origin header, so an explicit
// ":443" in the configured public URL must not lock browser clients out.
func TestAdminOriginCanonicalPublicURL(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	session := ts.login(t)
	for _, publicURL := range []string{"https://rctl.example.com:443/", "https://rctl.example.com:0443/"} {
		ts.relay.cfg.PublicURL = publicURL

		req, err := http.NewRequest(http.MethodPost, ts.URL+"/api/admin/sessions/revoke-others", nil)
		if err != nil {
			t.Fatal(err)
		}
		req.AddCookie(session.cookie)
		req.Header.Set("Origin", "https://rctl.example.com")
		resp, err := ts.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("public URL %q: canonical origin status = %d, want %d", publicURL, resp.StatusCode, http.StatusOK)
		}
	}
}

// An explicitly empty Origin header is not a state any browser produces;
// absence (no header at all) stays the non-browser client path.
func TestRequestOriginAllowedRejectsEmptyAndRepeated(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	ts.relay.cfg.PublicURL = ts.URL
	session := ts.login(t)

	req, err := http.NewRequest(http.MethodPost, ts.URL+"/api/admin/sessions/revoke-others", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.AddCookie(session.cookie)
	req.Header["Origin"] = []string{""}
	resp, err := ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("empty origin status = %d, want %d", resp.StatusCode, http.StatusForbidden)
	}

	req, err = http.NewRequest(http.MethodPost, ts.URL+"/api/admin/sessions/revoke-others", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.AddCookie(session.cookie)
	req.Header["Origin"] = []string{ts.URL, "https://sibling.evil.invalid"}
	resp, err = ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("repeated origin status = %d, want %d", resp.StatusCode, http.StatusForbidden)
	}
}

// Opening the control page from a sibling origin is a same-site navigation
// without an Origin header; only the strict tunnel guard rejects it while
// same-origin window.open and address-bar navigation keep working.
func TestControlPageSameSiteNavigationRejected(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	session := ts.login(t)
	now := time.Now().Unix()
	if _, err := ts.db.Exec(`INSERT INTO devices(id, name, status, created_at, updated_at) VALUES(?, ?, 'approved', ?, ?)`,
		"approved-ipad", "Test", now, now); err != nil {
		t.Fatal(err)
	}
	ts.relay.devices["approved-ipad"] = &deviceConn{id: "approved-ipad"}
	webDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(webDir, "index.html"), []byte("<html></html>"), 0644); err != nil {
		t.Fatal(err)
	}
	ts.relay.cfg.WebDir = webDir

	for _, tc := range []struct {
		name, fetchSite string
		want            int
	}{
		{"sibling window.open", "same-site", http.StatusForbidden},
		{"same-origin open", "same-origin", http.StatusOK},
		{"address-bar navigation", "none", http.StatusOK},
		{"non-browser client", "", http.StatusOK},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req, err := http.NewRequest(http.MethodGet, ts.URL+"/control/devices/approved-ipad", nil)
			if err != nil {
				t.Fatal(err)
			}
			req.AddCookie(session.cookie)
			if tc.fetchSite != "" {
				req.Header.Set("Sec-Fetch-Site", tc.fetchSite)
			}
			resp, err := ts.client.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != tc.want {
				t.Fatalf("status = %d, want %d", resp.StatusCode, tc.want)
			}
		})
	}
}
