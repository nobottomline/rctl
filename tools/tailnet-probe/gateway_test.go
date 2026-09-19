package main

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func testGateway(t *testing.T, backend http.Handler, authorize func(context.Context, string) bool) *gateway {
	t.Helper()
	upstream := httptest.NewServer(backend)
	t.Cleanup(upstream.Close)
	g, err := newGateway("rctl-test.example.ts.net", authorize)
	if err != nil {
		t.Fatal(err)
	}
	g.interval = 10 * time.Millisecond
	transport := g.proxy.Transport.(*http.Transport)
	transport.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		if addr != "127.0.0.1:8080" {
			t.Errorf("unexpected upstream destination %q", addr)
		}
		return (&net.Dialer{}).DialContext(ctx, network, upstream.Listener.Addr().String())
	}
	t.Cleanup(g.Close)
	return g
}

func lanPolicy(w http.ResponseWriter, r *http.Request) bool {
	if r.URL.Path != "/v1/local_access" {
		return false
	}
	w.Header().Set("Content-Type", "application/json")
	io.WriteString(w, `{"ok":true,"enabled":true,"mode":"lan"}`)
	return true
}

func TestGatewayBoundary(t *testing.T) {
	var upstreamRequests atomic.Int32
	g := testGateway(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if lanPolicy(w, r) {
			return
		}
		upstreamRequests.Add(1)
		for _, name := range []string{"Cookie", "Authorization", "Forwarded", "X-Forwarded-For", "Origin", "Referer", "Tailscale-User-Login"} {
			if r.Header.Get(name) != "" {
				t.Errorf("private/spoofable header forwarded: %s", name)
			}
		}
		if r.Host != "127.0.0.1:8080" {
			t.Error("unexpected upstream Host")
		}
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Set-Cookie", "untrusted=1")
		w.Header().Set("Cache-Control", "public")
		w.Header().Set("X-Frame-Options", "SAMEORIGIN")
		io.WriteString(w, "device-response")
	}), func(ctx context.Context, addr string) bool {
		if _, ok := ctx.Deadline(); !ok {
			t.Error("identity lookup has no deadline")
		}
		return addr == "100.64.0.1:4321"
	})
	for _, tc := range []struct {
		name, method, path, origin, referer, site string
		denied                                    bool
	}{
		{name: "document", method: "GET", path: "/"},
		{name: "query-on-document", method: "GET", path: "/?x=1", denied: true},
		{name: "same-origin", method: "GET", path: "/v1/deviceinfo", origin: g.origin},
		{name: "safari-referer", method: "GET", path: "/v1/deviceinfo", referer: g.origin + "/"},
		{name: "csrf-get", method: "GET", path: "/v1/button?name=home", denied: true},
		{name: "csrf-post", method: "POST", path: "/v1/keyboard", origin: "https://untrusted.example", denied: true},
		{name: "null-origin", method: "POST", path: "/v1/keyboard", origin: "null", denied: true},
		{name: "wrong-referer", method: "GET", path: "/v1/deviceinfo", referer: g.origin + ".evil/", denied: true},
		{name: "sibling-origin", method: "GET", path: "/v1/button", referer: "https://other.example.ts.net/", site: "same-site", denied: true},
		{name: "ingest", method: "POST", path: "/v1/cam_upload", origin: g.origin, denied: true},
		{name: "policy", method: "POST", path: "/v1/local_access", origin: g.origin, denied: true},
		{name: "update", method: "POST", path: "/v1/update", origin: g.origin, denied: true},
		{name: "future-route", method: "GET", path: "/v1/future", origin: g.origin, denied: true},
		{name: "encoded-path", method: "GET", path: "/v1/%64eviceinfo", origin: g.origin, denied: true},
		{name: "traversal", method: "GET", path: "/v1/../v1/deviceinfo", origin: g.origin, denied: true},
		{name: "prefix-match", method: "GET", path: "/inputevil", origin: g.origin, denied: true},
		{name: "large-target", method: "GET", path: "/v1/deviceinfo?" + strings.Repeat("x", 1024), origin: g.origin, denied: true},
		{name: "method", method: "DELETE", path: "/v1/rm", origin: g.origin, denied: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(tc.method, g.origin+tc.path, nil)
			// Server-side URL has no absolute-form authority.
			r.URL.Scheme, r.URL.Host = "", ""
			r.RemoteAddr = "100.64.0.1:4321"
			for name, value := range map[string]string{"Origin": tc.origin, "Referer": tc.referer, "Sec-Fetch-Site": tc.site} {
				if value != "" {
					r.Header.Set(name, value)
				}
			}
			for _, name := range []string{"Cookie", "Authorization", "Forwarded", "X-Forwarded-For", "Tailscale-User-Login"} {
				r.Header.Set(name, "synthetic-test-value")
			}
			before := upstreamRequests.Load()
			w := httptest.NewRecorder()
			g.ServeHTTP(w, r)
			if tc.denied {
				if w.Code != 403 || upstreamRequests.Load() != before {
					t.Fatalf("denial reached backend: status=%d", w.Code)
				}
			} else if w.Code != 200 || w.Body.String() != "device-response" {
				t.Fatalf("request failed: %d %s", w.Code, w.Body.String())
			}
			if w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("X-Frame-Options") != "DENY" ||
				w.Header().Get("Access-Control-Allow-Origin") != "" || w.Header().Get("Set-Cookie") != "" {
				t.Fatal("unsafe response headers")
			}
		})
	}
}

func TestGatewayFailsClosed(t *testing.T) {
	for _, tc := range []struct {
		name, policy string
		allowed      bool
	}{
		{"identity", `{"ok":true,"enabled":true,"mode":"lan"}`, false},
		{"relay-only", `{"ok":true,"enabled":false,"mode":"relay-only"}`, true},
		{"malformed", `not json`, true},
		{"truncated", `{"ok":true}`, true},
		{"oversized", strings.Repeat(" ", 4097), true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			g := testGateway(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/v1/local_access" {
					t.Error("denied request reached device API")
				}
				io.WriteString(w, tc.policy)
			}), func(context.Context, string) bool { return tc.allowed })
			r := httptest.NewRequest("GET", "/", nil)
			r.TLS = &tls.ConnectionState{}
			r.Host = strings.TrimPrefix(g.origin, "https://")
			w := httptest.NewRecorder()
			g.ServeHTTP(w, r)
			if w.Code != 403 {
				t.Fatal(w.Code)
			}
		})
	}
}

func TestGatewayRequestLimits(t *testing.T) {
	g, err := newGateway("rctl-test.example.ts.net", func(context.Context, string) bool {
		t.Error("invalid request reached identity service")
		return true
	})
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	for _, tc := range []struct {
		name string
		edit func(*http.Request)
		code int
	}{
		{"plaintext", func(r *http.Request) { r.TLS = nil }, 403},
		{"host", func(r *http.Request) { r.Host = "other.example.ts.net" }, 403},
		{"absolute-form", func(r *http.Request) { r.URL.Scheme = "https"; r.URL.Host = r.Host }, 403},
		{"oversized-body", func(r *http.Request) { r.ContentLength = 64 << 20 }, 413},
		{"chunked", func(r *http.Request) { r.TransferEncoding = []string{"chunked"} }, 413},
		{"unknown-length", func(r *http.Request) { r.ContentLength = -1 }, 413},
		{"ws-no-origin", func(r *http.Request) { r.URL.Path = "/ws/term"; r.Header.Set("Upgrade", "websocket") }, 403},
		{"duplicate-origin", func(r *http.Request) { r.Header["Origin"] = []string{g.origin, g.origin} }, 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest("GET", "/", nil)
			r.TLS = &tls.ConnectionState{}
			r.Host = strings.TrimPrefix(g.origin, "https://")
			tc.edit(r)
			w := httptest.NewRecorder()
			g.ServeHTTP(w, r)
			if w.Code != tc.code {
				t.Fatal(w.Code)
			}
		})
	}
}

func TestGatewayClosesWebSocket(t *testing.T) {
	for _, reason := range []string{"identity", "policy", "shutdown"} {
		t.Run(reason, func(t *testing.T) {
			var allowed, local atomic.Bool
			allowed.Store(true)
			local.Store(true)
			closed := make(chan struct{})
			g := testGateway(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/v1/local_access" {
					if local.Load() {
						lanPolicy(w, r)
					} else {
						w.WriteHeader(403)
					}
					return
				}
				c, err := websocket.Accept(w, r, nil)
				if err != nil {
					t.Error(err)
					return
				}
				defer c.CloseNow()
				defer close(closed)
				_, data, err := c.Read(r.Context())
				if err == nil {
					_ = c.Write(r.Context(), websocket.MessageText, data)
					_, _, _ = c.Read(r.Context())
				}
			}), func(context.Context, string) bool { return allowed.Load() })
			srv := httptest.NewTLSServer(g)
			defer srv.Close()
			g.origin = srv.URL
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			c, _, err := websocket.Dial(ctx, "wss"+strings.TrimPrefix(srv.URL, "https")+"/ws/signal", &websocket.DialOptions{
				HTTPClient: srv.Client(), HTTPHeader: http.Header{"Origin": {srv.URL}},
			})
			if err != nil {
				t.Fatal(err)
			}
			defer c.CloseNow()
			if err := c.Write(ctx, websocket.MessageText, []byte("synthetic-signal")); err != nil {
				t.Fatal(err)
			}
			if _, data, err := c.Read(ctx); err != nil || string(data) != "synthetic-signal" {
				t.Fatalf("WebSocket round trip failed: %v", err)
			}
			switch reason {
			case "identity":
				allowed.Store(false)
			case "policy":
				local.Store(false)
			case "shutdown":
				g.Close()
			}
			if _, _, err := c.Read(ctx); err == nil {
				t.Fatal("revoked WebSocket remained readable")
			}
			select {
			case <-closed:
			case <-ctx.Done():
				t.Fatal("device-side WebSocket did not close")
			}
		})
	}
}

func TestGatewayStreamingCancellation(t *testing.T) {
	var allowed atomic.Bool
	allowed.Store(true)
	closed := make(chan struct{})
	g := testGateway(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if lanPolicy(w, r) {
			return
		}
		defer close(closed)
		w.Header().Set("Content-Type", "application/octet-stream")
		io.WriteString(w, "first-chunk")
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}), func(context.Context, string) bool { return allowed.Load() })
	srv := httptest.NewTLSServer(g)
	defer srv.Close()
	g.origin = srv.URL
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	r, _ := http.NewRequestWithContext(ctx, "GET", srv.URL+"/v1/pull_stream?path=synthetic", nil)
	r.Header.Set("Referer", srv.URL+"/")
	resp, err := srv.Client().Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data := make([]byte, len("first-chunk"))
	if _, err := io.ReadFull(resp.Body, data); err != nil || string(data) != "first-chunk" {
		t.Fatalf("body buffered instead of streamed: %v", err)
	}
	allowed.Store(false)
	_, _ = io.Copy(io.Discard, resp.Body)
	select {
	case <-closed:
	case <-ctx.Done():
		t.Fatal("upstream download survived revocation")
	}
}

func TestGatewayQuotaAndHostValidation(t *testing.T) {
	for _, host := range []string{"", "example.com", "host.ts.net:443", "host.ts.net/", "UPPER.ts.net", "a..ts.net", "user@host.ts.net"} {
		if g, err := newGateway(host, nil); err == nil {
			g.Close()
			t.Errorf("invalid host accepted: %q", host)
		}
	}
	g, err := newGateway("rctl-test.example.ts.net", func(context.Context, string) bool {
		t.Error("over-quota request reached identity lookup")
		return true
	})
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	for range cap(g.slots) {
		g.slots <- struct{}{}
	}
	r := httptest.NewRequest("GET", "/", nil)
	r.Host = "rctl-test.example.ts.net"
	r.TLS = &tls.ConnectionState{}
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if w.Code != 503 {
		t.Fatal(w.Code)
	}
}
