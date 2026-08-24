package relay

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

type pairingFixture struct {
	V             int    `json:"v"`
	Origin        string `json:"origin"`
	PairingID     string `json:"pairing_id"`
	Secret        string `json:"secret"`
	ExpiresAt     int64  `json:"expires_at"`
	ProtocolMajor int    `json:"protocol_major"`
	RelayID       string `json:"relay_id"`
}

type claimFixture struct {
	Controller struct {
		ID       string   `json:"id"`
		Name     string   `json:"name"`
		Platform string   `json:"platform"`
		Scopes   []string `json:"scopes"`
	} `json:"controller"`
	Tokens controllerTokenPair `json:"tokens"`
}

func TestControllerPairingLifecycle(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	pairing := createPairingFixture(t, ts, admin, []string{"device.control", "screen.view"})

	if pairing.Origin != ts.URL || pairing.V != 1 || pairing.ProtocolMajor != protocolMajor || pairing.RelayID == "" {
		t.Fatalf("unexpected pairing payload: %#v", pairing)
	}
	var storedHash string
	if err := ts.db.QueryRow(`SELECT secret_hash FROM controller_pairings WHERE id=?`, pairing.PairingID).Scan(&storedHash); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(storedHash, pairing.Secret) || storedHash == pairing.PairingID+"."+pairing.Secret {
		t.Fatal("pairing secret stored in recoverable form")
	}

	key := newControllerKey(t)
	body := signedClaimBody(t, pairing, key, "Owner iPhone", "ios")
	claim := claimPairing(t, ts, pairing.PairingID, body, http.StatusCreated)
	if claim.Controller.Name != "Owner iPhone" || claim.Controller.Platform != "ios" ||
		claim.Tokens.AccessToken == "" || claim.Tokens.RefreshToken == "" {
		t.Fatalf("unexpected claim response: %#v", claim)
	}
	if strings.Join(claim.Controller.Scopes, ",") != "device.control,screen.view" {
		t.Fatalf("unexpected scopes: %v", claim.Controller.Scopes)
	}

	claimPairing(t, ts, pairing.PairingID, body, http.StatusUnauthorized)
	assertControllerTokensHashed(t, ts, claim)

	renameBody := bytes.NewBufferString(`{"name":"Travel phone"}`)
	resp := controllerRequest(t, ts, admin.cookie, http.MethodPost,
		"/api/admin/controllers/"+claim.Controller.ID+"/rename", renameBody)
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("rename status=%d", resp.StatusCode)
	}
	resp.Body.Close()

	resp = controllerRequest(t, ts, admin.cookie, http.MethodPost,
		"/api/admin/controllers/"+claim.Controller.ID+"/revoke", nil)
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("revoke status=%d", resp.StatusCode)
	}
	resp.Body.Close()
	var status string
	var liveTokens int
	if err := ts.db.QueryRow(`SELECT status FROM controllers WHERE id=?`, claim.Controller.ID).Scan(&status); err != nil {
		t.Fatal(err)
	}
	if err := ts.db.QueryRow(`SELECT COUNT(*) FROM controller_tokens WHERE controller_id=? AND revoked_at IS NULL`, claim.Controller.ID).Scan(&liveTokens); err != nil {
		t.Fatal(err)
	}
	if status != "revoked" || liveTokens != 0 {
		t.Fatalf("revocation status=%q live_tokens=%d", status, liveTokens)
	}
}

func TestControllerPairingRejectsBadInputsWithoutConsumption(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	pairing := createPairingFixture(t, ts, admin, []string{"screen.view"})
	key := newControllerKey(t)
	body := signedClaimBody(t, pairing, key, "My iPhone", "ios")
	var req map[string]any
	if err := json.Unmarshal(body, &req); err != nil {
		t.Fatal(err)
	}
	req["proof"] = base64.RawURLEncoding.EncodeToString([]byte("not-a-signature"))
	badBody, _ := json.Marshal(req)
	claimPairing(t, ts, pairing.PairingID, badBody, http.StatusUnauthorized)
	claimPairing(t, ts, pairing.PairingID, body, http.StatusCreated)

	expired := createPairingFixture(t, ts, admin, []string{"screen.view"})
	if _, err := ts.db.Exec(`UPDATE controller_pairings SET expires_at=? WHERE id=?`, time.Now().Add(-time.Minute).Unix(), expired.PairingID); err != nil {
		t.Fatal(err)
	}
	expiredBody := signedClaimBody(t, expired, newControllerKey(t), "Late phone", "ios")
	claimPairing(t, ts, expired.PairingID, expiredBody, http.StatusUnauthorized)

	reqBody := bytes.NewBufferString(`{"name":"bad","scopes":["relay.admin"],"ttl_seconds":300}`)
	resp := controllerRequest(t, ts, admin.cookie, http.MethodPost, "/api/admin/controller-pairings", reqBody)
	if resp.StatusCode != http.StatusBadRequest {
		resp.Body.Close()
		t.Fatalf("unknown scope status=%d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestControllerPairingCanBeRevokedBeforeClaim(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	pairing := createPairingFixture(t, ts, admin, []string{"screen.view"})

	resp := controllerRequest(t, ts, admin.cookie, http.MethodPost,
		"/api/admin/controller-pairings/"+pairing.PairingID+"/revoke", nil)
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("revoke pairing status=%d", resp.StatusCode)
	}
	resp.Body.Close()

	body := signedClaimBody(t, pairing, newControllerKey(t), "Revoked phone", "ios")
	claimPairing(t, ts, pairing.PairingID, body, http.StatusUnauthorized)

	resp = controllerRequest(t, ts, admin.cookie, http.MethodPost,
		"/api/admin/controller-pairings/"+pairing.PairingID+"/revoke", nil)
	if resp.StatusCode != http.StatusNotFound {
		resp.Body.Close()
		t.Fatalf("second revoke pairing status=%d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestControllerPairingConcurrentClaimIsSingleUse(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	pairing := createPairingFixture(t, ts, admin, []string{"screen.view"})
	body := signedClaimBody(t, pairing, newControllerKey(t), "Race phone", "ios")

	start := make(chan struct{})
	statuses := make(chan int, 2)
	var wg sync.WaitGroup
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			req, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/controller/pairings/"+pairing.PairingID+"/claim", bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			resp, err := ts.client.Do(req)
			if err != nil {
				statuses <- 0
				return
			}
			resp.Body.Close()
			statuses <- resp.StatusCode
		}()
	}
	close(start)
	wg.Wait()
	close(statuses)
	counts := map[int]int{}
	for status := range statuses {
		counts[status]++
	}
	if counts[http.StatusCreated] != 1 || counts[http.StatusUnauthorized] != 1 {
		t.Fatalf("concurrent statuses=%v", counts)
	}
}

func TestControllerProofReplayAndRefreshRotation(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	pairing := createPairingFixture(t, ts, admin, []string{"screen.view"})
	key := newControllerKey(t)
	claim := claimPairing(t, ts, pairing.PairingID,
		signedClaimBody(t, pairing, key, "Proof phone", "ios"), http.StatusCreated)

	nonce := randomControllerNonce(t)
	req := signedControllerRequest(t, ts, key, claim.Tokens.AccessToken, http.MethodGet,
		"/api/controller/me", nil, time.Now(), nonce)
	resp, err := ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("controller me status=%d", resp.StatusCode)
	}
	resp.Body.Close()

	// The exact same valid proof is a replay because its nonce was consumed.
	req = signedControllerRequest(t, ts, key, claim.Tokens.AccessToken, http.MethodGet,
		"/api/controller/me", nil, time.Now(), nonce)
	resp, err = ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusUnauthorized {
		resp.Body.Close()
		t.Fatalf("replay status=%d", resp.StatusCode)
	}
	resp.Body.Close()

	refreshReq := signedControllerRequest(t, ts, key, claim.Tokens.RefreshToken, http.MethodPost,
		"/api/controller/token/refresh", nil, time.Now(), randomControllerNonce(t))
	resp, err = ts.client.Do(refreshReq)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("refresh status=%d", resp.StatusCode)
	}
	var rotated struct {
		Tokens controllerTokenPair `json:"tokens"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&rotated); err != nil {
		resp.Body.Close()
		t.Fatal(err)
	}
	resp.Body.Close()
	if rotated.Tokens.AccessToken == claim.Tokens.AccessToken || rotated.Tokens.RefreshToken == claim.Tokens.RefreshToken {
		t.Fatal("refresh did not rotate both tokens")
	}

	for _, oldToken := range []string{claim.Tokens.AccessToken, claim.Tokens.RefreshToken} {
		path, method := "/api/controller/me", http.MethodGet
		if strings.HasPrefix(oldToken, "crt_") {
			path, method = "/api/controller/token/refresh", http.MethodPost
		}
		req = signedControllerRequest(t, ts, key, oldToken, method, path, nil, time.Now(), randomControllerNonce(t))
		resp, err = ts.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if resp.StatusCode != http.StatusUnauthorized {
			resp.Body.Close()
			t.Fatalf("old token %q status=%d", oldToken[:4], resp.StatusCode)
		}
		resp.Body.Close()
	}

	req = signedControllerRequest(t, ts, key, rotated.Tokens.AccessToken, http.MethodGet,
		"/api/controller/me", nil, time.Now(), randomControllerNonce(t))
	resp, err = ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("rotated access status=%d", resp.StatusCode)
	}
	resp.Body.Close()

	req = signedControllerRequest(t, ts, key, rotated.Tokens.AccessToken, http.MethodGet,
		"/api/controller/me", nil, time.Now().Add(-5*time.Minute), randomControllerNonce(t))
	resp, err = ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusUnauthorized {
		resp.Body.Close()
		t.Fatalf("stale timestamp status=%d", resp.StatusCode)
	}
	resp.Body.Close()
}

func createPairingFixture(t *testing.T, ts adminSessionTestServer, admin testSession, scopes []string) pairingFixture {
	t.Helper()
	body, _ := json.Marshal(controllerPairingRequest{Name: "Owner phone", Scopes: scopes, TTLSeconds: 300})
	resp := controllerRequest(t, ts, admin.cookie, http.MethodPost, "/api/admin/controller-pairings", bytes.NewReader(body))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create pairing status=%d", resp.StatusCode)
	}
	if resp.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("pairing cache control=%q", resp.Header.Get("Cache-Control"))
	}
	var envelope struct {
		Pairing pairingFixture `json:"pairing"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&envelope); err != nil {
		t.Fatal(err)
	}
	return envelope.Pairing
}

func newControllerKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func signedClaimBody(t *testing.T, pairing pairingFixture, key *ecdsa.PrivateKey, name, platform string) []byte {
	t.Helper()
	der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	fingerprintBytes := sha256.Sum256(der)
	fingerprint := base64.RawURLEncoding.EncodeToString(fingerprintBytes[:])
	digest := sha256.Sum256(pairingProofMessage(pairing.PairingID, pairing.Secret, normalizeControllerName(name), platform, fingerprint))
	proof, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(controllerClaimRequest{
		Secret: pairing.Secret, Name: name, Platform: platform,
		PublicKey: base64.RawURLEncoding.EncodeToString(der),
		Proof:     base64.RawURLEncoding.EncodeToString(proof),
	})
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func claimPairing(t *testing.T, ts adminSessionTestServer, id string, body []byte, want int) claimFixture {
	t.Helper()
	resp := controllerRequest(t, ts, nil, http.MethodPost, "/api/controller/pairings/"+id+"/claim", bytes.NewReader(body))
	defer resp.Body.Close()
	if resp.StatusCode != want {
		t.Fatalf("claim status=%d want=%d", resp.StatusCode, want)
	}
	var claim claimFixture
	if want == http.StatusCreated {
		if err := json.NewDecoder(resp.Body).Decode(&claim); err != nil {
			t.Fatal(err)
		}
	}
	return claim
}

func controllerRequest(t *testing.T, ts adminSessionTestServer, cookie *http.Cookie, method, path string, body io.Reader) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, ts.URL+path, body)
	if err != nil {
		t.Fatal(err)
	}
	if cookie != nil {
		req.AddCookie(cookie)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func assertControllerTokensHashed(t *testing.T, ts adminSessionTestServer, claim claimFixture) {
	t.Helper()
	for _, token := range []string{claim.Tokens.AccessToken, claim.Tokens.RefreshToken} {
		id, _, ok := strings.Cut(token, ".")
		if !ok {
			t.Fatalf("malformed token response")
		}
		var stored string
		if err := ts.db.QueryRow(`SELECT secret_hash FROM controller_tokens WHERE id=?`, id).Scan(&stored); err != nil {
			t.Fatal(err)
		}
		if stored == token || strings.Contains(stored, token) {
			t.Fatal("controller token stored in recoverable form")
		}
	}
}

func randomControllerNonce(t *testing.T) string {
	t.Helper()
	value := make([]byte, 24)
	if _, err := rand.Read(value); err != nil {
		t.Fatal(err)
	}
	return base64.RawURLEncoding.EncodeToString(value)
}

func signedControllerRequest(
	t *testing.T,
	ts adminSessionTestServer,
	key *ecdsa.PrivateKey,
	token, method, path string,
	body []byte,
	now time.Time,
	nonce string,
) *http.Request {
	t.Helper()
	req, err := http.NewRequest(method, ts.URL+path, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	tokenID, _, ok := strings.Cut(token, ".")
	if !ok {
		t.Fatal("malformed test token")
	}
	query, err := canonicalControllerQuery(req.URL.Query())
	if err != nil {
		t.Fatal(err)
	}
	bodyHash := sha256.Sum256(body)
	timestamp := now.Unix()
	message := controllerRequestProofMessage(
		tokenID, timestamp, nonce, method, req.URL.EscapedPath(), query,
		base64.RawURLEncoding.EncodeToString(bodyHash[:]),
	)
	digest := sha256.Sum256(message)
	signature, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-RCTL-Timestamp", strconv.FormatInt(timestamp, 10))
	req.Header.Set("X-RCTL-Nonce", nonce)
	req.Header.Set("X-RCTL-Signature", base64.RawURLEncoding.EncodeToString(signature))
	return req
}
