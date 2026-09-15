package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"mime"
	"net"
	"net/http"
	"strings"
	"time"
)

// The relay forwards only the supervisor's small fixed API, never an arbitrary
// URL or command. Cookie auth, CSRF checks, and admin rate limits wrap this route.
func (s *server) handleHostUpdates(w http.ResponseWriter, r *http.Request) {
	if s.cfg.HostUpdateSocket == "" {
		writeErr(w, http.StatusServiceUnavailable, "host_updates_not_managed")
		return
	}
	path := "/status"
	if r.Method == http.MethodPost {
		// SameSite cookies alone do not protect against a sibling-origin form.
		mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if err != nil || mediaType != "application/json" || (r.Header.Get("Origin") != "" && r.Header.Get("Origin") != strings.TrimSuffix(s.cfg.PublicURL, "/")) || r.Header.Get("Sec-Fetch-Site") == "cross-site" {
			writeErr(w, http.StatusForbidden, "invalid_update_origin")
			return
		}
		switch strings.TrimPrefix(r.URL.Path, "/api/admin/updates/") {
		case "check":
			path = "/check"
		case "install":
			path = "/install"
		case "policy":
			path = "/policy"
		default:
			writeErr(w, http.StatusNotFound, "not_found")
			return
		}
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1024))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_request")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", s.cfg.HostUpdateSocket)
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, _ := http.NewRequestWithContext(ctx, r.Method, "http://updater"+path, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+s.cfg.AdminSecret)
	resp, err := client.Do(req)
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "host_updater_unavailable")
		return
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, (64<<10)+1))
	if err != nil || len(body) > 64<<10 || !json.Valid(body) {
		writeErr(w, http.StatusBadGateway, "invalid_updater_response")
		return
	}
	if r.Method == http.MethodPost && resp.StatusCode == http.StatusOK {
		s.audit(r, "admin_host_update_request", "action", path)
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(body)
}
