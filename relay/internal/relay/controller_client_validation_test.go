package relay

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestControllerTelemetrySemanticBounds(t *testing.T) {
	for _, body := range []string{
		`{"telemetry":{"battery_level":101}}`,
		`{"telemetry":{"battery_level":-1}}`,
		`{"telemetry":{"battery_level":0.5}}`,
		`{"telemetry":{"battery_state":"running"}}`,
		`{"telemetry":{"thermal":"fair serious"}}`,
		`{"telemetry":{"network":"ethernet"}}`,
		`{"telemetry":{"lan_ip":"8.8.8.8"}}`,
		`{"telemetry":{"lan_ip":"::ffff:8.8.8.8"}}`,
		`{"telemetry":{"lan_ip":"127.0.0.1"}}`,
		`{"telemetry":{}} {}`,
		strings.Repeat(" ", controllerClientBodyMax+1),
	} {
		if _, err := readControllerTelemetry(httptest.NewRequest(http.MethodPost, "/", strings.NewReader(body))); err == nil {
			t.Errorf("accepted invalid telemetry: %.120s", body)
		}
	}
	for _, body := range []string{
		`{"telemetry":{"battery_level":0,"thermal":"unknown","lan_ip":"fd00::1","memory_available_bytes":0}}`,
		`{"telemetry":{"battery_level":100,"network":"wifi","lan_ip":"192.168.1.2","low_power":"false"}}`,
		`{"telemetry":{"disk_free_bytes":123,"uptime_seconds":123}}`,
		"",
	} {
		if _, err := readControllerTelemetry(httptest.NewRequest(http.MethodPost, "/", strings.NewReader(body))); err != nil {
			t.Fatal(err)
		}
	}
}

func TestControllerProfileRejectsTrailingAndOversizedBody(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	pairing := createPairingFixture(t, ts, admin, []string{"screen.view"})
	key := newControllerKey(t)
	claim := claimPairing(t, ts, pairing.PairingID, signedClaimBody(t, pairing, key, "Test", "ios"), http.StatusCreated)
	for _, body := range []string{`{"client":{}} {}`, `{"client":{}}` + strings.Repeat(" ", controllerClientBodyMax)} {
		req := signedControllerRequest(t, ts, key, claim.Tokens.AccessToken, http.MethodPost,
			"/api/controller/me/client", []byte(body), time.Now(), randomControllerNonce(t))
		resp, err := ts.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("got %d", resp.StatusCode)
		}
	}
}
