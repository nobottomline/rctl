package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"time"
)

// The experimental gateway can reach only the device-local rctl listener.
// It is not an arbitrary reverse proxy or a replacement for relay authorization.
const rctlBackend = "http://127.0.0.1:8080"

type gateway struct {
	origin    string
	authorize func(context.Context, string) bool
	policy    func(context.Context) bool
	proxy     *httputil.ReverseProxy
	slots     chan struct{}
	interval  time.Duration
	ctx       context.Context
	cancel    context.CancelFunc
}

func newGateway(host string, authorize func(context.Context, string) bool) (*gateway, error) {
	if host == "" || len(host) > 253 || host != strings.ToLower(host) || !strings.HasSuffix(host, ".ts.net") {
		return nil, errors.New("gateway requires its canonical Tailscale certificate name")
	}
	for _, label := range strings.Split(host, ".") {
		if err := validateIdentity(label, "1"); err != nil {
			return nil, errors.New("invalid gateway DNS name")
		}
	}
	target, _ := url.Parse(rctlBackend)
	transport := &http.Transport{
		Proxy:           nil,
		DialContext:     (&net.Dialer{Timeout: 3 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		MaxConnsPerHost: 40, MaxIdleConnsPerHost: 8,
		ResponseHeaderTimeout: 35 * time.Second, IdleConnTimeout: 30 * time.Second,
		DisableCompression: true,
	}
	ctx, cancel := context.WithCancel(context.Background())
	g := &gateway{
		origin: "https://" + host, authorize: authorize, slots: make(chan struct{}, 32),
		interval: 5 * time.Second, ctx: ctx, cancel: cancel,
	}
	g.policy = func(ctx context.Context) bool {
		request, _ := http.NewRequestWithContext(ctx, http.MethodGet, rctlBackend+"/v1/local_access", nil)
		response, err := transport.RoundTrip(request)
		if err != nil {
			return false
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			return false
		}
		data, err := io.ReadAll(io.LimitReader(response.Body, 4097))
		var state struct {
			OK      bool   `json:"ok"`
			Enabled bool   `json:"enabled"`
			Mode    string `json:"mode"`
		}
		return err == nil && len(data) <= 4096 && json.Unmarshal(data, &state) == nil &&
			state.OK && state.Enabled && state.Mode == "lan"
	}
	g.proxy = &httputil.ReverseProxy{
		Transport: transport,
		Rewrite: func(p *httputil.ProxyRequest) {
			p.SetURL(target)
			p.Out.Host = target.Host
			// Only headers required by the device protocol reach its small HTTP parser.
			headers := make(http.Header)
			for _, name := range []string{"Content-Type", "Accept", "Range", "Upgrade", "Connection", "Sec-WebSocket-Key", "Sec-WebSocket-Version"} {
				if values := p.Out.Header.Values(name); len(values) != 0 {
					headers[name] = values
				}
			}
			p.Out.Header = headers
		},
		ModifyResponse: func(r *http.Response) error {
			for name := range r.Header {
				if strings.HasPrefix(strings.ToLower(name), "access-control-") || strings.EqualFold(name, "Set-Cookie") {
					r.Header.Del(name)
				}
			}
			gatewayHeaders(r.Header)
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			http.Error(w, "Device connection unavailable", http.StatusBadGateway)
		},
		// URL queries can contain private file paths or command text.
		ErrorLog: log.New(io.Discard, "", 0),
	}
	return g, nil
}

func (g *gateway) Close() {
	g.cancel()
	g.proxy.Transport.(*http.Transport).CloseIdleConnections()
}

func (g *gateway) permitted(ctx context.Context, addr string) bool {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return g.authorize(ctx, addr) && g.policy(ctx)
}

func gatewayHeaders(h http.Header) {
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Content-Security-Policy", "frame-ancestors 'none'; object-src 'none'; base-uri 'none'")
	h.Set("Referrer-Policy", "same-origin")
}

func (g *gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	gatewayHeaders(w.Header())
	if r.TLS == nil || "https://"+r.Host != g.origin || !gatewayRoute(r) || !g.sameOrigin(r) {
		http.Error(w, "Forbidden", http.StatusForbidden)
		return
	}
	// The native parser consumes Content-Length, not chunked request bodies.
	if r.ContentLength < 0 || r.ContentLength >= 64<<20 || len(r.TransferEncoding) != 0 {
		http.Error(w, "Unsupported request body", http.StatusRequestEntityTooLarge)
		return
	}
	select {
	case g.slots <- struct{}{}:
		defer func() { <-g.slots }()
	default:
		http.Error(w, "Too many active requests", http.StatusServiceUnavailable)
		return
	}
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	stop := context.AfterFunc(g.ctx, cancel)
	defer stop()
	if !g.permitted(ctx, r.RemoteAddr) {
		http.Error(w, "Access unavailable", http.StatusForbidden)
		return
	}
	// Cancellation also closes ReverseProxy's upgraded WebSocket connection.
	// This lets rctld tear down its signal session, held input and media resources.
	go func() {
		ticker := time.NewTicker(g.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if !g.permitted(ctx, r.RemoteAddr) {
					cancel()
					return
				}
			}
		}
	}()
	g.proxy.ServeHTTP(&gatewayWriter{ResponseWriter: w, ctx: ctx}, r.WithContext(ctx))
}

// A stalled download must not pin a connection indefinitely. Keep a sliding
// write deadline instead of a total deadline that cuts off healthy large files.
type gatewayWriter struct {
	http.ResponseWriter
	ctx context.Context
}

func (w *gatewayWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *gatewayWriter) writeDeadline() error {
	if err := w.ctx.Err(); err != nil {
		return err
	}
	err := http.NewResponseController(w.ResponseWriter).SetWriteDeadline(time.Now().Add(10 * time.Second))
	if errors.Is(err, http.ErrNotSupported) {
		return nil
	}
	return err
}

func (w *gatewayWriter) Write(p []byte) (int, error) {
	if err := w.writeDeadline(); err != nil {
		return 0, err
	}
	return w.ResponseWriter.Write(p)
}

func (w *gatewayWriter) FlushError() error {
	if err := w.writeDeadline(); err != nil {
		return err
	}
	return http.NewResponseController(w.ResponseWriter).Flush()
}

func (g *gateway) sameOrigin(r *http.Request) bool {
	document := (r.URL.Path == "/" || r.URL.Path == "/index.html") && r.URL.RawQuery == "" && r.Method == http.MethodGet
	if values := r.Header.Values("Origin"); len(values) != 0 {
		return len(values) == 1 && values[0] == g.origin
	}
	if strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		return false
	}
	if document {
		return true
	}
	if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" {
		return false
	}
	// Safari versions without Fetch Metadata still supply a same-origin Referer.
	ref, err := url.Parse(r.Referer())
	return err == nil && ref.User == nil && ref.Scheme+"://"+ref.Host == g.origin
}

func gatewayRoute(r *http.Request) bool {
	if len(r.URL.RequestURI()) >= 1024 || r.URL.RawPath != "" || r.URL.Opaque != "" ||
		r.URL.IsAbs() || strings.ContainsAny(r.URL.Path, "%\\\x00\r\n") {
		return false
	}
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		return false
	}
	switch r.URL.Path {
	case "/", "/index.html", "/stream", "/input", "/key", "/config", "/orient", "/audio_test":
		return r.Method == http.MethodGet
	case "/ws/term":
		return r.Method == http.MethodGet && r.URL.RawQuery == ""
	case "/ws/signal":
		return r.Method == http.MethodGet && (r.URL.RawQuery == "" || r.URL.RawQuery == "media=camera")
	case "/v1/capabilities", "/v1/talk_route", "/v1/tap", "/v1/swipe", "/v1/key", "/v1/button",
		"/v1/type", "/v1/launch", "/v1/alert", "/v1/toast", "/v1/brightness", "/v1/audio_capture",
		"/v1/audio_output", "/v1/clipboard", "/v1/keyboard", "/v1/orientation", "/v1/deviceinfo",
		"/v1/diagnostics", "/v1/packages", "/v1/tweaks", "/v1/dylibs", "/v1/owner", "/v1/pkg_files",
		"/v1/pkg_meta", "/v1/apps", "/v1/openurl", "/v1/script", "/v1/ls", "/v1/pull", "/v1/pull_stream",
		"/v1/push", "/v1/say", "/v1/sound", "/v1/flash", "/v1/banner", "/v1/spook",
		"/v1/cam_live", "/v1/cam_status", "/v1/cam_record", "/v1/mic_capture", "/v1/mic_record",
		"/v1/camera", "/v1/screenshot", "/v1/confirmation", "/v1/rm", "/v1/tweak_toggle",
		"/v1/pkg_remove", "/v1/respring", "/v1/media_delete_token", "/v1/media_delete",
		"/v1/media", "/v1/media_asset", "/v1/media_thumb", "/v1/media_preview":
		return true
	default:
		// Ingest, future endpoints and access/update configuration are not proxied.
		return false
	}
}
