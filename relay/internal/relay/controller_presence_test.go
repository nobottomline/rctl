package relay

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestControllerPresenceLease(t *testing.T) {
	now := time.Unix(1700000000, 0)
	for _, test := range []struct {
		name, status string
		heartbeat    sql.NullInt64
		want         string
	}{
		{"legacy", "active", sql.NullInt64{}, "unknown"},
		{"fresh", "active", sql.NullInt64{Int64: now.Unix(), Valid: true}, "online"},
		{"expired", "active", sql.NullInt64{Int64: now.Add(-controllerPresenceTTL).Unix(), Valid: true}, "offline"},
		{"revoked", "revoked", sql.NullInt64{Int64: now.Unix(), Valid: true}, "offline"},
		{"clock rollback", "active", sql.NullInt64{Int64: now.Add(time.Second).Unix(), Valid: true}, "offline"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := controllerPresence(test.status, test.heartbeat, now); got != test.want {
				t.Fatalf("got %s, want %s", got, test.want)
			}
		})
	}
}

func TestControllerSelfRevokeAndPresence(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	pairing := createPairingFixture(t, ts, admin, []string{"screen.view"})
	key := newControllerKey(t)
	claim := claimPairing(t, ts, pairing.PairingID, signedClaimBody(t, pairing, key, "Phone", "ios"), http.StatusCreated)
	otherPairing := createPairingFixture(t, ts, admin, []string{"screen.view"})
	other := claimPairing(t, ts, otherPairing.PairingID, signedClaimBody(t, otherPairing, newControllerKey(t), "Other", "ios"), http.StatusCreated)

	request := func(path, token, nonce string, want int) {
		t.Helper()
		req := signedControllerRequest(t, ts, key, token, http.MethodPost, path, nil, time.Now(), nonce)
		resp, err := ts.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != want {
			t.Fatalf("%s: got %d want %d", path, resp.StatusCode, want)
		}
	}
	list := func(want string, sessions int) {
		t.Helper()
		resp := controllerRequest(t, ts, admin.cookie, http.MethodGet, "/api/admin/controllers", nil)
		defer resp.Body.Close()
		var body struct {
			Controllers []struct {
				ID, Presence string
				OpenSessions int `json:"open_sessions"`
			}
		}
		if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		for _, row := range body.Controllers {
			if row.ID == claim.Controller.ID {
				if row.Presence != want || row.OpenSessions != sessions {
					t.Fatalf("presence=%s sessions=%d", row.Presence, row.OpenSessions)
				}
				return
			}
		}
		t.Fatal("controller missing")
	}
	list("unknown", 0)
	nonce := randomControllerNonce(t)
	request("/api/controller/presence", claim.Tokens.AccessToken, nonce, http.StatusOK)
	request("/api/controller/presence", claim.Tokens.AccessToken, nonce, http.StatusUnauthorized)
	list("online", 0)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	otherCtx, otherCancel := context.WithCancel(context.Background())
	defer otherCancel()
	ts.relay.registerControllerSignal(claim.Controller.ID, "screen", cancel)
	ts.relay.registerControllerSignal(other.Controller.ID, "other", otherCancel)
	list("online", 1)
	if _, err := ts.db.Exec(`UPDATE controllers SET heartbeat_at=? WHERE id=?`, time.Now().Add(-2*time.Minute).Unix(), claim.Controller.ID); err != nil {
		t.Fatal(err)
	}
	// An open signaling socket must not pretend to prove foreground presence.
	list("offline", 1)
	request("/api/controller/me/revoke", claim.Tokens.AccessToken, randomControllerNonce(t), http.StatusOK)
	if ctx.Err() == nil {
		t.Fatal("self revoke left its session open")
	}
	if otherCtx.Err() != nil {
		t.Fatal("self revoke closed another controller")
	}
	list("offline", 0)
	var status string
	if err := ts.db.QueryRow(`SELECT status FROM controllers WHERE id=?`, other.Controller.ID).Scan(&status); err != nil || status != "active" {
		t.Fatal("other controller changed", err)
	}
	var live int
	if err := ts.db.QueryRow(`SELECT COUNT(*) FROM controller_tokens WHERE controller_id=? AND revoked_at IS NULL`, claim.Controller.ID).Scan(&live); err != nil || live != 0 {
		t.Fatal("live revoked credentials", err)
	}
	request("/api/controller/presence", claim.Tokens.AccessToken, randomControllerNonce(t), http.StatusUnauthorized)
	request("/api/controller/token/refresh", claim.Tokens.RefreshToken, randomControllerNonce(t), http.StatusUnauthorized)
	request("/api/controller/me/revoke", other.Tokens.AccessToken, randomControllerNonce(t), http.StatusUnauthorized)
}

func TestPresenceLimitsAndRevocationRace(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	pairing := createPairingFixture(t, ts, admin, []string{"screen.view"})
	key := newControllerKey(t)
	claim := claimPairing(t, ts, pairing.PairingID, signedClaimBody(t, pairing, key, "Phone", "ios"), http.StatusCreated)
	for i := 0; i < 7; i++ {
		req := signedControllerRequest(t, ts, key, claim.Tokens.AccessToken, http.MethodPost, "/api/controller/presence", nil, time.Now(), randomControllerNonce(t))
		resp, err := ts.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		want := http.StatusOK
		if i == 6 {
			want = http.StatusTooManyRequests
		}
		if resp.StatusCode != want {
			t.Fatalf("pulse %d status=%d", i, resp.StatusCode)
		}
	}
	if err := ts.relay.migrate(context.Background()); err != nil {
		t.Fatal("repeat migration", err)
	}
	if _, err := ts.db.Exec(`UPDATE controllers SET status='revoked' WHERE id=?`, claim.Controller.ID); err != nil {
		t.Fatal(err)
	}
	// Simulate a previously authenticated request racing revocation.
	ts.relay.limiter = newRateLimiter(time.Minute)
	req := httptest.NewRequest(http.MethodPost, "/api/controller/presence", nil)
	req = req.WithContext(context.WithValue(req.Context(), controllerContextKey{}, controllerPrincipal{ControllerID: claim.Controller.ID}))
	w := httptest.NewRecorder()
	ts.relay.handleControllerPresence(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("race status=%d", w.Code)
	}
}

func TestPresenceMigrationPreservesExistingController(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	pairing := createPairingFixture(t, ts, admin, []string{"screen.view"})
	claim := claimPairing(t, ts, pairing.PairingID, signedClaimBody(t, pairing, newControllerKey(t), "Existing", "ios"), http.StatusCreated)
	// Recreate the previous schema with real paired data before applying migration.
	if _, err := ts.db.Exec(`ALTER TABLE controllers DROP COLUMN heartbeat_at`); err != nil {
		t.Fatal(err)
	}
	if err := ts.relay.migrate(context.Background()); err != nil {
		t.Fatal(err)
	}
	var heartbeat sql.NullInt64
	var status string
	if err := ts.db.QueryRow(`SELECT status,heartbeat_at FROM controllers WHERE id=?`, claim.Controller.ID).Scan(&status, &heartbeat); err != nil {
		t.Fatal(err)
	}
	if status != "active" || heartbeat.Valid {
		t.Fatal("migration changed controller authorization or fabricated presence")
	}
}
