package relay

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func TestControllerSignalScopes(t *testing.T) {
	principal := controllerPrincipal{
		ControllerID: "ctl_1",
		Scopes: map[string]struct{}{
			"device.control": {},
			"screen.view":    {},
		},
	}
	r := httptest.NewRequest(http.MethodGet, "/api/controller/devices/dev1/signal", nil)
	r = r.WithContext(context.WithValue(r.Context(), controllerContextKey{}, principal))

	scopes, controllerID, ok := controllerSignalScopes(r, "screen")
	if !ok || controllerID != "ctl_1" || len(scopes) != 2 ||
		scopes[0] != "device.control" || scopes[1] != "screen.view" {
		t.Fatalf("unexpected screen authorization: scopes=%v controller=%q ok=%t", scopes, controllerID, ok)
	}
	if _, _, ok := controllerSignalScopes(r, "camera"); ok {
		t.Fatal("screen-only controller was authorized for camera")
	}

	adminRequest := httptest.NewRequest(http.MethodGet, "/signal/devices/dev1", nil)
	adminScopes, adminID, ok := controllerSignalScopes(adminRequest, "screen")
	if !ok || adminScopes != nil || adminID != "" {
		t.Fatalf("legacy admin path changed: scopes=%v controller=%q ok=%t", adminScopes, adminID, ok)
	}
}

func TestSignalOpenPayloadScopesAreExplicitOnlyForControllers(t *testing.T) {
	adminPayload, err := json.Marshal(signalOpenPayload{Role: "screen", ICE: json.RawMessage(`[]`)})
	if err != nil {
		t.Fatal(err)
	}
	if string(adminPayload) != `{"role":"screen","ice":[]}` {
		t.Fatalf("admin payload unexpectedly changed: %s", adminPayload)
	}
	controllerPayload, err := json.Marshal(signalOpenPayload{
		Role: "screen", ICE: json.RawMessage(`[]`), Scopes: []string{"screen.view"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if json.Unmarshal(controllerPayload, &decoded) != nil || decoded["scopes"] == nil {
		t.Fatalf("controller payload omitted scopes: %s", controllerPayload)
	}
}

func TestRevokingControllerCancelsItsSignalSessions(t *testing.T) {
	s := &server{}
	first := false
	second := false
	other := false
	s.registerControllerSignal("ctl_1", "sig_1", func() { first = true })
	s.registerControllerSignal("ctl_1", "sig_2", func() { second = true })
	s.registerControllerSignal("ctl_2", "sig_3", func() { other = true })

	s.closeControllerSignals("ctl_1")
	if !first || !second || other {
		t.Fatalf("unexpected cancellation first=%t second=%t other=%t", first, second, other)
	}
	s.controllerSignalsMu.Lock()
	_, revokedStillRegistered := s.controllerSignals["ctl_1"]
	_, otherStillRegistered := s.controllerSignals["ctl_2"]
	s.controllerSignalsMu.Unlock()
	if revokedStillRegistered || !otherStillRegistered {
		t.Fatalf("unexpected registry state revoked=%t other=%t", revokedStillRegistered, otherStillRegistered)
	}
}

func newSignalDeviceConn() *deviceConn {
	return &deviceConn{
		pendingHTTP:   make(map[string]chan httpTunnelResponse),
		pendingStream: make(map[string]chan streamTunnelEvent),
		pendingTerm:   make(map[string]chan termTunnelEvent),
		pendingSignal: make(map[string]chan signalTunnelEvent),
	}
}

func TestSignalControlMessageRoutesToSession(t *testing.T) {
	dc := newSignalDeviceConn()
	ch := make(chan signalTunnelEvent, 4)
	dc.registerSignal("sig_1", ch)

	if !dc.handleControlMessage([]byte(`{"type":"webrtc_signal","id":"sig_1","kind":"offer","payload":{"sdp":"v=0"}}`)) {
		t.Fatal("handleControlMessage did not consume webrtc_signal")
	}
	select {
	case ev := <-ch:
		if ev.Kind != "offer" || string(ev.Payload) != `{"sdp":"v=0"}` {
			t.Fatalf("unexpected event: %+v", ev)
		}
	default:
		t.Fatal("no event delivered to session channel")
	}

	// A signal for an unknown session is still consumed but dropped (no panic).
	if !dc.handleControlMessage([]byte(`{"type":"webrtc_signal","id":"unknown","kind":"ice"}`)) {
		t.Fatal("unknown-session signal not consumed")
	}

	// close must unregister the session.
	dc.handleControlMessage([]byte(`{"type":"webrtc_signal","id":"sig_1","kind":"close"}`))
	dc.mu.Lock()
	_, stillThere := dc.pendingSignal["sig_1"]
	dc.mu.Unlock()
	if stillThere {
		t.Fatal("close did not unregister the signal session")
	}
}

func TestControllerSignalMessagesFailClosed(t *testing.T) {
	valid := []signalClientMessage{
		{Kind: "answer", Payload: json.RawMessage(`{"sdp":"v=0"}`)},
		{Kind: "candidate", Payload: json.RawMessage(`{"candidate":"candidate:1","mid":"0"}`)},
	}
	for _, message := range valid {
		if !validControllerSignalMessage(message) {
			t.Fatalf("valid message rejected: %+v", message)
		}
	}
	invalid := []signalClientMessage{
		{Kind: "open", Payload: json.RawMessage(`{"role":"screen"}`)},
		{Kind: "offer", Payload: json.RawMessage(`{"sdp":"v=0"}`)},
		{Kind: "ready", Payload: json.RawMessage(`[]`)},
		{Kind: "answer", Payload: json.RawMessage(`{"sdp":""}`)},
		{Kind: "candidate", Payload: json.RawMessage(`{"candidate":""}`)},
		{Kind: "candidate", Payload: json.RawMessage(`null`)},
		{Kind: "unknown", Payload: json.RawMessage(`{}`)},
	}
	for _, message := range invalid {
		if validControllerSignalMessage(message) {
			t.Fatalf("invalid message accepted: %+v", message)
		}
	}
}

func TestSignalWSGates(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })

	s := &server{
		cfg:     config{EnableWebRTC: false},
		db:      db,
		devices: make(map[string]*deviceConn),
		limiter: newRateLimiter(5 * time.Minute),
	}
	if err := s.migrate(context.Background()); err != nil {
		t.Fatal(err)
	}

	now := time.Now().Unix()
	if _, err := db.ExecContext(context.Background(),
		`INSERT INTO devices(id, name, status, created_at, updated_at) VALUES(?,?,?,?,?)`,
		"dev1", "dev1", "approved", now, now,
	); err != nil {
		t.Fatal(err)
	}
	sessionID, secret := "sess1", "secret1"
	if _, err := db.ExecContext(context.Background(),
		`INSERT INTO sessions(id, secret_hash, expires_at, created_at, last_seen_at) VALUES(?,?,?,?,?)`,
		sessionID, hmacToken(s.cfg.SessionSecret, secret), now+3600, now, now,
	); err != nil {
		t.Fatal(err)
	}

	mux := http.NewServeMux()
	s.routes(mux)
	ts := httptest.NewServer(s.securityHeaders(mux))
	t.Cleanup(ts.Close)
	cookie := &http.Cookie{Name: "rctl_session", Value: sessionID + "." + secret}

	// No admin session -> 401, before any websocket upgrade.
	resp, err := ts.Client().Get(ts.URL + "/signal/devices/dev1")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no-admin status=%d, want 401", resp.StatusCode)
	}

	// Admin session but WebRTC disabled -> 404 webrtc_disabled.
	req, _ := http.NewRequest("GET", ts.URL+"/signal/devices/dev1", nil)
	req.AddCookie(cookie)
	resp2, err := ts.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusNotFound {
		t.Fatalf("disabled status=%d, want 404", resp2.StatusCode)
	}
}

func TestSignalWSRejectsUnknownMediaRole(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })

	s := &server{
		cfg:     config{EnableWebRTC: true},
		db:      db,
		devices: make(map[string]*deviceConn),
		limiter: newRateLimiter(5 * time.Minute),
	}
	if err := s.migrate(context.Background()); err != nil {
		t.Fatal(err)
	}
	now := time.Now().Unix()
	if _, err := db.ExecContext(context.Background(),
		`INSERT INTO devices(id, name, status, created_at, updated_at) VALUES(?,?,?,?,?)`,
		"dev1", "dev1", "approved", now, now); err != nil {
		t.Fatal(err)
	}
	s.devices["dev1"] = newSignalDeviceConn()
	sessionID, secret := "sess1", "secret1"
	if _, err := db.ExecContext(context.Background(),
		`INSERT INTO sessions(id, secret_hash, expires_at, created_at, last_seen_at) VALUES(?,?,?,?,?)`,
		sessionID, hmacToken(s.cfg.SessionSecret, secret), now+3600, now, now); err != nil {
		t.Fatal(err)
	}

	mux := http.NewServeMux()
	s.routes(mux)
	ts := httptest.NewServer(s.securityHeaders(mux))
	t.Cleanup(ts.Close)
	req, _ := http.NewRequest("GET", ts.URL+"/signal/devices/dev1?media=audio", nil)
	req.AddCookie(&http.Cookie{Name: "rctl_session", Value: sessionID + "." + secret})
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("invalid media status=%d, want 400", resp.StatusCode)
	}
}
