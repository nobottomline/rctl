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

func TestControllerGrantRenewalAndLivePermissionChange(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	ts.relay.cfg.EnableWebRTC = true
	ts.relay.cfg.WriteTimeout = time.Second
	ts.relay.cfg.ReadLimitBytes = 1 << 20
	admin := ts.login(t)
	pairing := createPairingFixture(t, ts, admin, []string{"screen.view", "device.control"})
	key := newControllerKey(t)
	claim := claimPairing(t, ts, pairing.PairingID, signedClaimBody(t, pairing, key, "Phone", "ios"), 201)
	if _, err := ts.db.Exec(`INSERT INTO devices(id,name,status,created_at,updated_at) VALUES('dev','Test','approved',1,1)`); err != nil {
		t.Fatal(err)
	}
	dc := newSignalDeviceConn()
	dc.id = "dev"
	dc.features = []string{"controller.scoped_sessions", "controller.authorization_lease_v1"}
	ready := make(chan struct{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	deviceServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer ws.CloseNow()
		dc.ws = ws
		close(ready)
		for {
			_, raw, err := ws.Read(ctx)
			if err != nil {
				return
			}
			dc.handleControlMessage(raw)
		}
	}))
	defer deviceServer.Close()
	device, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(deviceServer.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer device.CloseNow()
	<-ready
	ts.relay.registerDevice(dc)
	req := signedControllerRequest(t, ts, key, claim.Tokens.AccessToken, "GET", "/api/controller/devices/dev/signal", nil, time.Now(), randomControllerNonce(t))
	controller, resp, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(req.URL.String(), "http"), &websocket.DialOptions{HTTPHeader: req.Header})
	if err != nil {
		t.Fatalf("signal dial: %v (%v)", err, resp)
	}
	defer controller.CloseNow()
	readDevice := func(want string) signalTunnelEvent {
		t.Helper()
		var event signalTunnelEvent
		if err := wsjsonRead(ctx, device, &event); err != nil {
			t.Fatal(err)
		}
		if event.Kind != want {
			t.Fatalf("got %s want %s", event.Kind, want)
		}
		return event
	}
	open := readDevice("open")
	var payload signalOpenPayload
	if json.Unmarshal(open.Payload, &payload) != nil || payload.AuthorizationRevision != 1 {
		t.Fatal("missing grant revision")
	}
	var clientReady signalClientMessage
	if err := wsjsonRead(ctx, controller, &clientReady); err != nil {
		t.Fatal(err)
	}
	challenge := signalTunnelEvent{Type: "webrtc_signal", ID: open.ID, Kind: "authorization_challenge", Payload: json.RawMessage(`{"nonce":"` + strings.Repeat("a", 64) + `","authorization_revision":1}`)}
	if err := wsjsonWrite(ctx, device, challenge); err != nil {
		t.Fatal(err)
	}
	renewed := readDevice("authorization_renew")
	if string(renewed.Payload) != string(challenge.Payload) {
		t.Fatal("challenge not bound to reply")
	}
	response := controllerRequest(t, ts, admin.cookie, "POST", "/api/admin/controllers/"+claim.Controller.ID+"/permissions", strings.NewReader(`{"scopes":["screen.view"],"expected_revision":1}`))
	response.Body.Close()
	if response.StatusCode != 200 {
		t.Fatalf("save: %d", response.StatusCode)
	}
	// Read the policy close concurrently so the WebSocket close handshake can
	// finish before the relay sends the device teardown.
	closed := make(chan error, 1)
	go func() { _, _, err := controller.Read(ctx); closed <- err }()
	readDevice("close")
	if err := <-closed; websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("not an authorization close: %v", err)
	}
	if ts.relay.controllerGrantCurrent(ctx, claim.Controller.ID, 1) {
		t.Fatal("old grant renewed")
	}
}
