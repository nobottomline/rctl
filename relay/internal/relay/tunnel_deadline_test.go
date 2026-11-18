package relay

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// A client that stops reading its tunnel response must not hold the device's
// admission slot and byte charge forever: the response write runs under a
// deadline, so the handler exits and the deferred unregisterHTTP releases
// everything.
func TestTunnelWriteDeadlineReleasesSlot(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	session := ts.login(t)
	ts.relay.cfg.TunnelTimeout = 400 * time.Millisecond
	ts.relay.cfg.WriteTimeout = 5 * time.Second

	now := time.Now().Unix()
	if _, err := ts.db.Exec(`INSERT INTO devices(id, name, status, created_at, updated_at) VALUES(?, ?, 'approved', ?, ?)`,
		"deadline-ipad", "Test", now, now); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	dc := &deviceConn{
		id:             "deadline-ipad",
		pendingHTTP:    make(map[string]chan httpTunnelResponse),
		pendingHTTPBuf: make(map[string]*httpBodyBuf),
		bodyHeld:       make(map[string]int64),
		features:       []string{},
	}
	// A fake device connection that answers each tunnel request with one large
	// response (replying to the request's own id), big enough to fill the
	// socket buffer and block the write.
	deviceServer := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer ws.CloseNow()
		for {
			_, raw, err := ws.Read(ctx)
			if err != nil {
				return
			}
			var req struct {
				ID string `json:"id"`
			}
			if json.Unmarshal(raw, &req) != nil || req.ID == "" {
				continue
			}
			dc.handleControlMessage([]byte(`{"type":"http_response","id":"` + req.ID + `","status":200,"body":"` + strings.Repeat("QUJD", 2<<19) + `"}`))
		}
	})
	deviceSrv := httptest.NewServer(deviceServer)
	t.Cleanup(deviceSrv.Close)
	deviceWS, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(deviceSrv.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = deviceWS.Close(websocket.StatusNormalClosure, "") }()
	dc.ws = deviceWS
	ts.relay.devices["deadline-ipad"] = dc

	req, err := http.NewRequest(http.MethodGet, ts.URL+"/proxy/devices/deadline-ipad/v1/info", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.AddCookie(session.cookie)
	resp, err := ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() // the body is deliberately never read
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("tunnel status = %d, want 200 with a blocked body write", resp.StatusCode)
	}

	// While the blocked write holds the response, the slot and byte charge
	// stay accounted.
	heldDeadline := time.Now().Add(3 * time.Second)
	for {
		dc.mu.Lock()
		held := len(dc.bodyHeld)
		bytes := dc.bufBytes
		dc.mu.Unlock()
		if held == 1 && bytes > 0 {
			break
		}
		if time.Now().After(heldDeadline) {
			t.Fatalf("response body was never accounted while held: %d held, bufBytes %d", held, bytes)
		}
		time.Sleep(10 * time.Millisecond)
	}

	// After the write deadline passes, the handler must exit and release the
	// slot and the byte charge.
	releaseDeadline := time.Now().Add(10 * time.Second)
	for {
		dc.mu.Lock()
		pending := len(dc.pendingHTTP) + len(dc.bodyHeld)
		bytes := dc.bufBytes
		dc.mu.Unlock()
		if pending == 0 && bytes == 0 {
			break
		}
		if time.Now().After(releaseDeadline) {
			t.Fatalf("slot or byte charge leaked: %d pending, %d bytes", pending, bytes)
		}
		time.Sleep(20 * time.Millisecond)
	}
}
