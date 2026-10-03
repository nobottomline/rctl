package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

type guestFixture struct {
	s     *server
	mux   *http.ServeMux
	admin *http.Cookie
}

func newGuestFixture(t *testing.T) guestFixture {
	t.Helper()
	s, _ := newAuthTestServer(t)
	s.cfg.SessionSecret = "disposable-guest-test-session-secret"
	s.cfg.PublicURL = "https://relay.example.invalid"
	s.cfg.EnableWebRTC = true
	s.cfg.SessionLifetime = time.Hour
	s.cfg.AllowInsecure = true
	s.cfg.WriteTimeout = time.Second
	s.cfg.ReadLimitBytes = 1 << 20
	s.cfg.TurnSecret = "disposable-turn-secret"
	s.cfg.TurnURLs = []string{"turn:turn.example.invalid"}
	s.cfg.AdminLimit = rateLimitConfig{Max: 1000, Window: time.Minute}
	s.limiter = newRateLimiter(time.Minute)
	s.devices = map[string]*deviceConn{}
	now := time.Now().Unix()
	if _, err := s.db.Exec(`INSERT INTO devices(id,name,status,created_at,updated_at) VALUES('test-device','Test device','approved',?,?)`, now, now); err != nil {
		t.Fatal(err)
	}
	dc := newSignalDeviceConn()
	dc.id = "test-device"
	dc.features = []string{guestCapability}
	s.registerDevice(dc)
	mux := http.NewServeMux()
	s.routes(mux)
	// Use the real login handler and session DB. Every request uses disposable state.
	s.cfg.AdminSecret = "disposable-guest-admin-secret"
	r := httptest.NewRequest("POST", "/api/admin/login", strings.NewReader(`{"secret":"disposable-guest-admin-secret"}`))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("login %d: %s", w.Code, w.Body.String())
	}
	var admin *http.Cookie
	for _, cookie := range w.Result().Cookies() {
		if cookie.Name == "rctl_session" {
			admin = cookie
		}
	}
	if admin == nil {
		t.Fatal("no admin cookie")
	}
	return guestFixture{s, mux, admin}
}
func (f guestFixture) request(t *testing.T, method, path string, body any, cookies ...*http.Cookie) *httptest.ResponseRecorder {
	t.Helper()
	var data []byte
	if body != nil {
		data, _ = json.Marshal(body)
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(data))
	r.Header.Set("Origin", f.s.cfg.PublicURL)
	r.Header.Set("Content-Type", "application/json")
	for _, c := range cookies {
		r.AddCookie(c)
	}
	w := httptest.NewRecorder()
	f.mux.ServeHTTP(w, r)
	return w
}
func (f guestFixture) create(t *testing.T, permissions ...string) (string, string) {
	t.Helper()
	w := f.request(t, "POST", "/api/admin/guest-grants", map[string]any{"device_id": "test-device", "label": "Test guest", "permissions": permissions, "ttl_seconds": 3600}, f.admin)
	if w.Code != 201 {
		t.Fatalf("create %d: %s", w.Code, w.Body.String())
	}
	var response struct {
		ID  string `json:"id"`
		URL string `json:"invitation_url"`
	}
	json.Unmarshal(w.Body.Bytes(), &response)
	if strings.Contains(response.URL, "test-device") {
		t.Fatal("invitation leaks device identifier")
	}
	_, secret, _ := strings.Cut(response.URL, "#")
	return response.ID, secret
}
func responseCookie(t *testing.T, w *httptest.ResponseRecorder, name string) *http.Cookie {
	t.Helper()
	for _, c := range w.Result().Cookies() {
		if c.Name == name {
			return c
		}
	}
	t.Fatalf("missing %s cookie: %d %s", name, w.Code, w.Body.String())
	return nil
}
func (f guestFixture) prepare(t *testing.T) *http.Cookie {
	return responseCookie(t, f.request(t, "POST", "/api/guest/prepare", map[string]any{}), guestClaimCookie)
}
func (f guestFixture) claim(t *testing.T, id, secret string, binding *http.Cookie) *httptest.ResponseRecorder {
	return f.request(t, "POST", "/api/guest/claim", map[string]any{"invitation_id": id, "secret": secret}, binding)
}
func TestGuestInvitationClaimRecoveryAndIsolation(t *testing.T) {
	f := newGuestFixture(t)
	id, secret := f.create(t, "screen.view")
	landing := f.request(t, "GET", "/share/"+id, nil)
	if landing.Code != 200 || !strings.Contains(landing.Header().Get("Content-Security-Policy"), "frame-ancestors 'none'") || landing.Header().Get("Referrer-Policy") != "no-referrer" {
		t.Fatal("unprotected landing")
	}
	var claimed any
	if err := f.s.db.QueryRow(`SELECT claimed_at FROM guest_grants WHERE id=?`, id).Scan(&claimed); err != nil || claimed != nil {
		t.Fatal("GET consumed invitation")
	}
	binding := f.prepare(t)
	first := f.claim(t, id, secret, binding)
	if first.Code != 200 {
		t.Fatalf("claim %d %s", first.Code, first.Body.String())
	}
	cookie := responseCookie(t, first, guestCookie)
	pending := httptest.NewRequest("POST", "/api/guest/claim/ack", strings.NewReader(`{}`))
	pending.AddCookie(cookie)
	oldPrincipal, err := f.s.authenticateGuest(pending)
	if err != nil {
		t.Fatal(err)
	}
	pending = pending.WithContext(context.WithValue(pending.Context(), guestContextKey{}, oldPrincipal))
	if !cookie.Secure || !cookie.HttpOnly || cookie.Path != "/" || cookie.Domain != "" || cookie.SameSite != http.SameSiteStrictMode {
		t.Fatal("weak guest cookie")
	}
	if w := f.claim(t, id, secret, f.prepare(t)); w.Code != 410 {
		t.Fatalf("second browser claim %d", w.Code)
	}
	recovered := f.claim(t, id, secret, binding)
	if recovered.Code != 200 {
		t.Fatalf("lost-response retry %d", recovered.Code)
	}
	next := responseCookie(t, recovered, guestCookie)
	if next.Value == cookie.Value {
		t.Fatal("recovery did not rotate credential")
	}
	if f.request(t, "GET", "/api/guest/session", nil, cookie).Code != 401 {
		t.Fatal("old recovery cookie active")
	}
	if f.s.guestGrantCurrent(context.Background(), oldPrincipal) {
		t.Fatal("rotated cookie retained authority for a pending signaling open")
	}
	for _, handler := range []http.HandlerFunc{f.s.handleGuestAck, f.s.handleGuestEnd} {
		response := httptest.NewRecorder()
		handler(response, pending)
		if response.Code != 401 {
			t.Fatal("stale authenticated request mutated recovered session")
		}
	}
	var acknowledged bool
	if err := f.s.db.QueryRow(`SELECT acknowledged FROM guest_grants WHERE id=?`, id).Scan(&acknowledged); err != nil || acknowledged {
		t.Fatal("stale ACK closed the current recovery window")
	}
	session := f.request(t, "GET", "/api/guest/session", nil, next, f.admin)
	if session.Code != 200 || strings.Contains(session.Body.String(), "test-device") || strings.Contains(session.Body.String(), "secret") {
		t.Fatal("session leaked private identity")
	}
	// A guest cannot access owner APIs or native-controller APIs.
	for _, path := range []string{"/api/admin/devices", "/control/devices/test-device", "/proxy/devices/test-device/v1/files", "/stream/devices/test-device/stream", "/term/devices/test-device", "/signal/devices/test-device", "/api/controller/devices"} {
		w := f.request(t, "GET", path, nil, next)
		if w.Code >= 200 && w.Code < 300 {
			t.Fatalf("guest escaped via %s: %d", path, w.Code)
		}
	}
	ack := f.request(t, "POST", "/api/guest/claim/ack", map[string]any{}, next)
	if ack.Code != 200 {
		t.Fatal("ack failed")
	}
	if f.claim(t, id, secret, binding).Code != 410 {
		t.Fatal("ack did not close recovery window")
	}
	var invitationHash string
	f.s.db.QueryRow(`SELECT invitation_hash FROM guest_grants WHERE id=?`, id).Scan(&invitationHash)
	if strings.Contains(invitationHash, secret) {
		t.Fatal("plaintext invitation stored")
	}
}
func TestGuestClaimConcurrentWinner(t *testing.T) {
	f := newGuestFixture(t)
	id, secret := f.create(t, "screen.view")
	a, b := f.prepare(t), f.prepare(t)
	var wg sync.WaitGroup
	codes := make(chan int, 2)
	for _, binding := range []*http.Cookie{a, b} {
		wg.Add(1)
		go func(c *http.Cookie) { defer wg.Done(); codes <- f.claim(t, id, secret, c).Code }(binding)
	}
	wg.Wait()
	close(codes)
	counts := map[int]int{}
	for code := range codes {
		counts[code]++
	}
	if counts[200] != 1 || counts[410] != 1 {
		t.Fatalf("claim race %v", counts)
	}
}
func TestGuestPermissionsRevocationAndExpiry(t *testing.T) {
	f := newGuestFixture(t)
	id, secret := f.create(t, "screen.view", "input.touch")
	cookie := responseCookie(t, f.claim(t, id, secret, f.prepare(t)), guestCookie)
	r := httptest.NewRequest("GET", "/api/guest/session", nil)
	r.AddCookie(cookie)
	original, err := f.s.authenticateGuest(r)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	connection := &guestConnection{cancel: cancel, done: make(chan struct{})}
	if !f.s.registerGuestConnection(original, "test-signal", connection) {
		t.Fatal("register")
	}
	go func() { <-ctx.Done(); connection.confirmed = true; close(connection.done) }()
	path := "/api/admin/guest-grants/" + id + "/permissions"
	same := f.request(t, "POST", path, map[string]any{"permissions": []string{"input.touch", "screen.view"}, "expected_revision": 1}, f.admin)
	if same.Code != 200 || ctx.Err() != nil {
		t.Fatal("no-op closes guest")
	}
	changed := f.request(t, "POST", path, map[string]any{"permissions": []string{"screen.view"}, "expected_revision": 1}, f.admin)
	if changed.Code != 200 || ctx.Err() == nil || !strings.Contains(changed.Body.String(), `"disconnect_confirmed":true`) {
		t.Fatalf("permissions did not disconnect: %d %s", changed.Code, changed.Body.String())
	}
	if f.s.guestGrantCurrent(context.Background(), original) {
		t.Fatal("old revision remains authorized")
	}
	if f.request(t, "POST", path, map[string]any{"permissions": []string{"screen.view", "input.touch"}, "expected_revision": 1}, f.admin).Code != 409 {
		t.Fatal("stale update overwrote rights")
	}
	f.s.unregisterGuestConnection(id, "test-signal")
	if f.request(t, "POST", "/api/admin/guest-grants/"+id+"/delete", map[string]any{}, f.admin).Code != 409 {
		t.Fatal("deleted active grant")
	}
	if f.request(t, "POST", "/api/admin/guest-grants/"+id+"/revoke", map[string]any{}, f.admin).Code != 200 {
		t.Fatal("revoke")
	}
	if f.request(t, "GET", "/api/guest/session", nil, cookie).Code != 401 {
		t.Fatal("revoked cookie allowed")
	}
	if f.claim(t, id, secret, f.prepare(t)).Code != 410 {
		t.Fatal("revoked invite reclaimed")
	}
	id2, secret2 := f.create(t, "screen.view")
	cookie2 := responseCookie(t, f.claim(t, id2, secret2, f.prepare(t)), guestCookie)
	f.s.db.Exec(`UPDATE guest_grants SET expires_at=? WHERE id=?`, time.Now().Unix(), id2)
	if f.request(t, "GET", "/api/guest/session", nil, cookie2).Code != 401 {
		t.Fatal("expired cookie allowed")
	}
	if f.request(t, "POST", "/api/admin/guest-grants/"+id2+"/delete", map[string]any{}, f.admin).Code != 200 {
		t.Fatal("expired history not removable")
	}
}
func TestGuestFailsClosedAndRequiresSameOrigin(t *testing.T) {
	f := newGuestFixture(t)
	for _, permissions := range [][]string{{}, {"input.unknown"}, {"screen.view", "terminal"}, {"screen.view", "device.control"}} {
		w := f.request(t, "POST", "/api/admin/guest-grants", map[string]any{"device_id": "test-device", "permissions": permissions, "ttl_seconds": 3600}, f.admin)
		if w.Code != 400 {
			t.Fatalf("invalid rights %v: %d", permissions, w.Code)
		}
	}
	r := httptest.NewRequest("POST", "/api/guest/prepare", strings.NewReader(`{}`))
	r.Header.Set("Origin", "https://evil.example.invalid")
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	f.mux.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("cross-origin claim allowed")
	}
	f.s.cfg.TurnSecret = ""
	if w := f.request(t, "POST", "/api/admin/guest-grants", map[string]any{"device_id": "test-device", "permissions": []string{"screen.view"}, "ttl_seconds": 3600}, f.admin); w.Code != 409 {
		t.Fatal("TURN-less invite silently permits P2P")
	}
	f.s.devices["test-device"].features = nil
	if w := f.request(t, "POST", "/api/admin/guest-grants", map[string]any{"device_id": "test-device", "permissions": []string{"screen.view"}, "ttl_seconds": 3600, "allow_direct": true}, f.admin); w.Code != 409 {
		t.Fatal("old device accepted guest")
	}
}
func TestGuestRevokeAllAndEndSession(t *testing.T) {
	f := newGuestFixture(t)
	var cookies []*http.Cookie
	for i := 0; i < 2; i++ {
		id, secret := f.create(t, "screen.view")
		cookies = append(cookies, responseCookie(t, f.claim(t, id, secret, f.prepare(t)), guestCookie))
	}
	if f.request(t, "POST", "/api/guest/session/end", map[string]any{}, cookies[0]).Code != 200 || f.request(t, "GET", "/api/guest/session", nil, cookies[0]).Code != 401 {
		t.Fatal("guest cannot end own access")
	}
	if f.request(t, "GET", "/api/guest/session", nil, cookies[1]).Code != 200 {
		t.Fatal("end affected another guest")
	}
	if f.request(t, "POST", "/api/admin/guest-grants/revoke-all", map[string]any{}, f.admin).Code != 200 {
		t.Fatal("revoke all")
	}
	if f.request(t, "GET", "/api/guest/session", nil, cookies[1]).Code != 401 {
		t.Fatal("revoke all retained access")
	}
}
func TestGuestScopePayloadAlwaysIncludesPrivacyPolicy(t *testing.T) {
	direct := false
	raw, err := json.Marshal(signalOpenPayload{Role: "screen", AccessMode: "guest-v1", Permissions: []string{"screen.view"}, AuthorizationRevision: 1, AllowDirect: &direct})
	if err != nil || !strings.Contains(string(raw), `"allow_direct":false`) || strings.Contains(string(raw), `"scopes"`) {
		t.Fatal("ambiguous device guest policy")
	}
}

func TestGuestSignalRevocationAcknowledgesDeviceRetirement(t *testing.T) {
	for _, scenario := range []struct {
		name, role  string
		permissions []string
	}{
		{"screen", "screen", []string{"screen.view", "input.touch"}},
		{"screenless_files", "operations", []string{"files.list", "files.upload"}},
		{"camera_without_screen", "camera", []string{"camera.live"}},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			f := newGuestFixture(t)
			f.s.getDevice("test-device").features = []string{guestCapability, "guest.operations_v1"}
			id, secret := f.create(t, scenario.permissions...)
			cookie := responseCookie(t, f.claim(t, id, secret, f.prepare(t)), guestCookie)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			dc := f.s.getDevice("test-device")
			ready := make(chan struct{})
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
			ts := httptest.NewServer(f.mux)
			defer ts.Close()
			headers := http.Header{"Origin": []string{f.s.cfg.PublicURL}, "Cookie": []string{cookie.String()}}
			browser, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/api/guest/signal?media="+scenario.role, &websocket.DialOptions{HTTPHeader: headers})
			if err != nil {
				t.Fatal(err)
			}
			defer browser.CloseNow()
			var open signalTunnelEvent
			if wsjsonRead(ctx, device, &open) != nil || open.Kind != "open" {
				t.Fatal("no scoped device open")
			}
			var payload signalOpenPayload
			json.Unmarshal(open.Payload, &payload)
			if payload.Role != scenario.role || payload.AccessMode != "guest-v1" || payload.AllowDirect == nil || *payload.AllowDirect || payload.AuthorizationRevision != 1 {
				t.Fatal("guest scope missing at device")
			}
			var clientReady signalClientMessage
			if wsjsonRead(ctx, browser, &clientReady) != nil || clientReady.Kind != "ready" {
				t.Fatal("no client ready")
			}
			challenge := signalTunnelEvent{Type: "webrtc_signal", ID: open.ID, Kind: "authorization_challenge", Payload: json.RawMessage(fmt.Sprintf(`{"nonce":%q,"authorization_revision":1}`, strings.Repeat("a", 64)))}
			if wsjsonWrite(ctx, device, challenge) != nil {
				t.Fatal("challenge")
			}
			var renewed signalTunnelEvent
			if wsjsonRead(ctx, device, &renewed) != nil || renewed.Kind != "authorization_renew" {
				t.Fatal("no device renewal")
			}
			var renewal struct {
				Remaining int `json:"remaining_ms"`
			}
			json.Unmarshal(renewed.Payload, &renewal)
			if renewal.Remaining < 1 || renewal.Remaining > 20000 {
				t.Fatal("unbounded guest lease")
			}
			result := make(chan *httptest.ResponseRecorder, 1)
			go func() {
				result <- f.request(t, "POST", "/api/admin/guest-grants/"+id+"/revoke", map[string]any{}, f.admin)
			}()
			// The browser does not read/respond to a close frame: revoke cannot depend on it.
			var closeEvent signalTunnelEvent
			if wsjsonRead(ctx, device, &closeEvent) != nil || closeEvent.Kind != "close" {
				t.Fatal("no immediate device retirement")
			}
			select {
			case <-result:
				t.Fatal("revocation claimed confirmation before device ack")
			default:
			}
			if wsjsonWrite(ctx, device, signalTunnelEvent{Type: "webrtc_signal", ID: open.ID, Kind: "closed"}) != nil {
				t.Fatal("ack")
			}
			response := <-result
			if response.Code != 200 || !strings.Contains(response.Body.String(), `"disconnect_confirmed":true`) {
				t.Fatalf("unconfirmed revoke %d %s", response.Code, response.Body.String())
			}
			readCtx, stop := context.WithTimeout(ctx, time.Second)
			defer stop()
			if _, _, err := browser.Read(readCtx); err == nil {
				t.Fatal("browser kept receiving after revoke")
			}
			if f.s.guestGrantCurrent(ctx, guestPrincipal{GrantID: id, DeviceID: "test-device", Revision: 1}) {
				t.Fatal("old authority renewed")
			}
		})
	}
}

func TestGuestControlBootstrapPreservesInlineScriptContents(t *testing.T) {
	f := newGuestFixture(t)
	id, secret := f.create(t, "screen.view")
	cookie := responseCookie(t, f.claim(t, id, secret, f.prepare(t)), guestCookie)
	f.s.cfg.WebDir = t.TempDir()
	source := `<!doctype html><html><head><meta name="rctl-guest-client" content="1"><script type="module">const a="<script>";const b="<script data-test>";</script></head><body><div id="root"></div></body></html>`
	if err := os.WriteFile(filepath.Join(f.s.cfg.WebDir, "index.html"), []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	response := f.request(t, "GET", "/guest/control", nil, cookie)
	if response.Code != 200 {
		t.Fatalf("bootstrap %d %s", response.Code, response.Body.String())
	}
	body := response.Body.String()
	if !strings.Contains(body, `const a="<script>";const b="<script data-test>";`) || strings.Count(body, `nonce="`) != 2 {
		t.Fatal("CSP injection rewrote JavaScript string literals")
	}
	if strings.Contains(body, "test-device") || !strings.Contains(body, "window.RCTL_GUEST_BOOTSTRAP=") {
		t.Fatal("invalid guest bootstrap")
	}
	f.s.db.Exec(`UPDATE guest_grants SET label=? WHERE id=?`, `</script><script>alert(1)</script>`, id)
	response = f.request(t, "GET", "/guest/control", nil, cookie)
	if strings.Contains(response.Body.String(), `</script><script>alert(1)`) {
		t.Fatal("guest label escaped JSON into HTML")
	}
}

func TestGuestAdvancedRightsRequireCurrentOperationsDevice(t *testing.T) {
	f := newGuestFixture(t)
	for _, rights := range [][]string{{"files.list"}, {"screen.view", "audio.microphone.listen"}, {"camera.live"}} {
		w := f.request(t, "POST", "/api/admin/guest-grants", map[string]any{"device_id": "test-device", "permissions": rights, "ttl_seconds": 3600}, f.admin)
		if w.Code != 409 {
			t.Fatalf("old device accepted advanced rights: %d", w.Code)
		}
	}
	f.s.getDevice("test-device").features = []string{guestCapability, "guest.operations_v1"}
	id, secret := f.create(t, "files.list", "files.upload")
	cookie := responseCookie(t, f.claim(t, id, secret, f.prepare(t)), guestCookie)
	if f.request(t, "GET", "/api/guest/session", nil, cookie).Code != 200 {
		t.Fatal("screenless session denied")
	}
	for _, role := range []string{"screen", "camera"} {
		if f.request(t, "GET", "/api/guest/signal?media="+role, nil, cookie).Code != 403 {
			t.Fatal("unauthorized media role accepted")
		}
	}
	f.s.getDevice("test-device").features = []string{guestCapability}
	if f.request(t, "GET", "/api/guest/signal?media=operations", nil, cookie).Code != 409 {
		t.Fatal("downgraded device accepted operations")
	}
}
