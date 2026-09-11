package relay

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestControllerPermissionsLifecycle(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	pairing := createPairingFixture(t, ts, admin, []string{"screen.view", "device.control"})
	key := newControllerKey(t)
	claim := claimPairing(t, ts, pairing.PairingID, signedClaimBody(t, pairing, key, "Phone", "ios"), http.StatusCreated)
	id := claim.Controller.ID
	path := "/api/admin/controllers/" + id + "/permissions"
	old, cancel := context.WithCancel(context.Background())
	other, cancelOther := context.WithCancel(context.Background())
	defer cancel()
	defer cancelOther()
	ts.relay.registerControllerSignal(id, "screen", cancel)
	ts.relay.registerControllerSignal("ctl_other", "screen", cancelOther)
	update := func(body string, want int) {
		t.Helper()
		resp := controllerRequest(t, ts, admin.cookie, "POST", path, strings.NewReader(body))
		defer resp.Body.Close()
		if resp.StatusCode != want {
			t.Fatalf("update got %d want %d", resp.StatusCode, want)
		}
	}
	for _, body := range []string{
		`{"scopes":[],"expected_revision":1}`,
		`{"scopes":["relay.admin"],"expected_revision":1}`,
		`{"scopes":["screen.view"]}`,
		`{"scopes":["screen.view"],"expected_revision":1} {}`,
		`{"scopes":["screen.view"],"expected_revision":1,"extra":true}`,
	} {
		update(body, http.StatusBadRequest)
	}
	update(`{"scopes":["screen.view","device.control"],"expected_revision":1}`, http.StatusOK)
	if old.Err() != nil {
		t.Fatal("no-op disconnected session")
	}
	update(`{"scopes":["screen.view"],"expected_revision":1}`, http.StatusOK)
	if old.Err() == nil || other.Err() != nil {
		t.Fatal("incorrect session cancellation")
	}
	if ts.relay.controllerGrantCurrent(context.Background(), id, 1) || !ts.relay.controllerGrantCurrent(context.Background(), id, 2) {
		t.Fatal("stale grant remains valid")
	}
	update(`{"scopes":["camera"],"expected_revision":1}`, http.StatusConflict)
	req := signedControllerRequest(t, ts, key, claim.Tokens.AccessToken, "GET", "/api/controller/me", nil, time.Now(), randomControllerNonce(t))
	resp, err := ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var info struct {
		Controller struct {
			Scopes   []string
			Revision int64 `json:"authorization_revision"`
		}
	}
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 || info.Controller.Revision != 2 || strings.Join(info.Controller.Scopes, ",") != "screen.view" {
		t.Fatalf("stale me: %+v", info)
	}
	var tokens int
	if err := ts.db.QueryRow(`SELECT COUNT(*) FROM controller_tokens WHERE controller_id=? AND revoked_at IS NULL`, id).Scan(&tokens); err != nil || tokens != 2 {
		t.Fatal("pairing credentials changed", err)
	}
	update(`{"scopes":["camera","screen.view"],"expected_revision":2}`, http.StatusOK)
	// Returning to the original scope set must not revive revision 1.
	update(`{"scopes":["screen.view","device.control"],"expected_revision":3}`, http.StatusOK)
	if ts.relay.controllerGrantCurrent(context.Background(), id, 1) {
		t.Fatal("ABA grant accepted")
	}
	resp = controllerRequest(t, ts, admin.cookie, "POST", "/api/admin/controllers/"+id+"/revoke", nil)
	resp.Body.Close()
	update(`{"scopes":["screen.view"],"expected_revision":4}`, http.StatusConflict)
	if ts.relay.controllerGrantCurrent(context.Background(), id, 4) {
		t.Fatal("revoked grant accepted")
	}
}

func TestControllerPermissionsConcurrentCASAndAdminBoundary(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	pairing := createPairingFixture(t, ts, admin, []string{"screen.view"})
	key := newControllerKey(t)
	claim := claimPairing(t, ts, pairing.PairingID, signedClaimBody(t, pairing, key, "Phone", "ios"), http.StatusCreated)
	path := "/api/admin/controllers/" + claim.Controller.ID + "/permissions"
	req := signedControllerRequest(t, ts, key, claim.Tokens.AccessToken, "POST", path,
		[]byte(`{"scopes":["camera"],"expected_revision":1}`), time.Now(), randomControllerNonce(t))
	resp, err := ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatalf("controller edited its own grants: %d", resp.StatusCode)
	}
	var wg sync.WaitGroup
	results := make(chan int, 2)
	for _, scope := range []string{"camera", "device.control"} {
		wg.Add(1)
		go func(scope string) {
			defer wg.Done()
			body := fmt.Sprintf(`{"scopes":["screen.view",%q],"expected_revision":1}`, scope)
			req, _ := http.NewRequest("POST", ts.URL+path, strings.NewReader(body))
			req.AddCookie(admin.cookie)
			req.Header.Set("Content-Type", "application/json")
			resp, err := ts.client.Do(req)
			if err != nil {
				results <- 0
				return
			}
			defer resp.Body.Close()
			results <- resp.StatusCode
		}(scope)
	}
	wg.Wait()
	close(results)
	counts := map[int]int{}
	for code := range results {
		counts[code]++
	}
	if counts[200] != 1 || counts[409] != 1 {
		t.Fatalf("CAS result: %v", counts)
	}
	if err := ts.relay.migrate(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !ts.relay.controllerGrantCurrent(context.Background(), claim.Controller.ID, 2) {
		t.Fatal("migration reset revision")
	}
}

func TestAuthorizationChallengeCannotComeFromController(t *testing.T) {
	payload := json.RawMessage(`{"nonce":"` + strings.Repeat("a", 64) + `","authorization_revision":1}`)
	if !validDeviceSignalMessage(signalTunnelEvent{Kind: "authorization_challenge", Payload: payload}) {
		t.Fatal("valid challenge rejected")
	}
	for _, kind := range []string{"authorization_challenge", "authorization_renew"} {
		if validControllerSignalMessage(signalClientMessage{Kind: kind, Payload: payload}) {
			t.Fatal("controller can renew authorization")
		}
	}
	for _, payload := range []string{`{}`, `null`, `{"nonce":"short","authorization_revision":1}`, `{"nonce":"` + strings.Repeat("a", 64) + `","authorization_revision":0}`} {
		if validDeviceSignalMessage(signalTunnelEvent{Kind: "authorization_challenge", Payload: json.RawMessage(payload)}) {
			t.Fatal("invalid challenge accepted")
		}
	}
}
