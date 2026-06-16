package relay

import (
	"context"
	"database/sql"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

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

	if !dc.handleControlMessage([]byte(`{"type":"webrtc_signal","id":"sig_1","kind":"sdp","payload":{"x":1}}`)) {
		t.Fatal("handleControlMessage did not consume webrtc_signal")
	}
	select {
	case ev := <-ch:
		if ev.Kind != "sdp" || string(ev.Payload) != `{"x":1}` {
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
		sessionID, hashToken(secret), now+3600, now, now,
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
