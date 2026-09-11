package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"
)

type controllerListRow struct {
	ID             string         `json:"id"`
	Name           string         `json:"name"`
	Status         string         `json:"status"`
	KeyFingerprint string         `json:"key_fingerprint"`
	PairedIP       string         `json:"paired_ip"`
	LastIP         string         `json:"last_ip"`
	UserAgent      string         `json:"user_agent"`
	Client         map[string]any `json:"client"`
	Telemetry      map[string]any `json:"telemetry"`
}

func listControllers(t *testing.T, ts adminSessionTestServer, admin testSession) []controllerListRow {
	t.Helper()
	resp := controllerRequest(t, ts, admin.cookie, http.MethodGet, "/api/admin/controllers", nil)
	defer resp.Body.Close()
	var body struct {
		Controllers []controllerListRow `json:"controllers"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	return body.Controllers
}

func findController(rows []controllerListRow, id string) *controllerListRow {
	for i := range rows {
		if rows[i].ID == id {
			return &rows[i]
		}
	}
	return nil
}

type auditRow struct {
	Event      string `json:"event"`
	Detail     string `json:"detail"`
	ActorKind  string `json:"actor_kind"`
	ActorID    string `json:"actor_id"`
	ActorLabel string `json:"actor_label"`
	ActorUA    string `json:"actor_ua"`
}

func listAudit(t *testing.T, ts adminSessionTestServer, admin testSession) []auditRow {
	t.Helper()
	resp := ts.get(t, admin.cookie, "/api/admin/audit?limit=500", http.StatusOK)
	defer resp.Body.Close()
	var body struct {
		Audit []auditRow `json:"audit"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	return body.Audit
}

func findAudit(rows []auditRow, event string) *auditRow {
	for i := range rows {
		if rows[i].Event == event {
			return &rows[i]
		}
	}
	return nil
}

func TestAdminControllerDeleteRequiresRevocation(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	pairing := createPairingFixture(t, ts, admin, []string{"screen.view"})
	claim := claimPairing(t, ts, pairing.PairingID, signedClaimBody(t, pairing, newControllerKey(t), "Grigorij's iPhone", "ios"), http.StatusCreated)
	id := claim.Controller.ID

	ts.post(t, admin.cookie, "/api/admin/controllers/"+id+"/delete", http.StatusConflict)
	if row := findController(listControllers(t, ts, admin), id); row == nil || row.Status != "active" {
		t.Fatalf("active controller must survive a delete attempt: %#v", row)
	}
	ts.post(t, admin.cookie, "/api/admin/controllers/"+id+"/revoke", http.StatusOK)
	ts.post(t, admin.cookie, "/api/admin/controllers/"+id+"/delete", http.StatusOK)
	if row := findController(listControllers(t, ts, admin), id); row != nil {
		t.Fatalf("deleted controller still listed: %#v", row)
	}
	ts.post(t, admin.cookie, "/api/admin/controllers/"+id+"/delete", http.StatusNotFound)

	var tokens int
	if err := ts.db.QueryRow(`SELECT count(*) FROM controller_tokens WHERE controller_id=?`, id).Scan(&tokens); err != nil || tokens != 0 {
		t.Fatalf("tokens not cascaded: %d %v", tokens, err)
	}
	deleted := findAudit(listAudit(t, ts, admin), "controller_deleted")
	if deleted == nil || deleted.ActorKind != "admin" || deleted.ActorID != admin.id {
		t.Fatalf("controller_deleted must be attributed to the admin session: %#v", deleted)
	}
	var detail map[string]any
	if json.Unmarshal([]byte(deleted.Detail), &detail) != nil || detail["controller_name"] != "Grigorij's iPhone" {
		t.Fatalf("controller_deleted must snapshot the name: %s", deleted.Detail)
	}
}

func TestAdminControllerClearHistory(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	var ids []string
	for _, name := range []string{"one", "two", "keep"} {
		pairing := createPairingFixture(t, ts, admin, []string{"screen.view"})
		claim := claimPairing(t, ts, pairing.PairingID, signedClaimBody(t, pairing, newControllerKey(t), name, "ios"), http.StatusCreated)
		ids = append(ids, claim.Controller.ID)
	}
	ts.post(t, admin.cookie, "/api/admin/controllers/"+ids[0]+"/revoke", http.StatusOK)
	ts.post(t, admin.cookie, "/api/admin/controllers/"+ids[1]+"/revoke", http.StatusOK)
	resp := ts.post(t, admin.cookie, "/api/admin/controllers/clear-history", http.StatusOK)
	var result struct {
		Deleted int `json:"deleted"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&result)
	resp.Body.Close()
	if result.Deleted != 2 {
		t.Fatalf("deleted=%d want 2", result.Deleted)
	}
	rows := listControllers(t, ts, admin)
	if len(rows) != 1 || rows[0].ID != ids[2] || rows[0].Status != "active" {
		t.Fatalf("clear-history must keep active controllers only: %#v", rows)
	}
}

func TestAdminEnrollmentDeleteRequiresTerminalState(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	create := func(ttl int64) string {
		t.Helper()
		body, _ := json.Marshal(enrollmentOptions{Label: "iPad", TTLSeconds: ttl})
		resp := controllerRequest(t, ts, admin.cookie, http.MethodPost, "/api/admin/enrollments", bytes.NewReader(body))
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusCreated {
			t.Fatalf("create enrollment status=%d", resp.StatusCode)
		}
		var created struct {
			Token string `json:"token"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&created)
		id, _, _ := bytes.Cut([]byte(created.Token), []byte("."))
		return string(id)
	}
	never := create(-1)
	ts.post(t, admin.cookie, "/api/admin/enrollments/"+never+"/delete", http.StatusConflict)
	ts.post(t, admin.cookie, "/api/admin/enrollments/"+never+"/revoke", http.StatusOK)
	ts.post(t, admin.cookie, "/api/admin/enrollments/"+never+"/delete", http.StatusOK)
	ts.post(t, admin.cookie, "/api/admin/enrollments/"+never+"/delete", http.StatusNotFound)

	expired := create(60)
	if _, err := ts.db.Exec(`UPDATE enrollments SET expires_at=? WHERE id=?`, time.Now().Add(-time.Hour).Unix(), expired); err != nil {
		t.Fatal(err)
	}
	active := create(3600)
	revoked := create(3600)
	ts.post(t, admin.cookie, "/api/admin/enrollments/"+revoked+"/revoke", http.StatusOK)

	resp := ts.post(t, admin.cookie, "/api/admin/enrollments/clear-history", http.StatusOK)
	var result struct {
		Deleted int `json:"deleted"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&result)
	resp.Body.Close()
	if result.Deleted != 2 {
		t.Fatalf("deleted=%d want 2 (expired + revoked)", result.Deleted)
	}
	var remaining string
	if err := ts.db.QueryRow(`SELECT group_concat(id) FROM enrollments`).Scan(&remaining); err != nil || remaining != active {
		t.Fatalf("remaining=%q want only %q (%v)", remaining, active, err)
	}
}

func TestAuditActorAttribution(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	pairing := createPairingFixture(t, ts, admin, []string{"screen.view"})
	key := newControllerKey(t)
	claim := claimPairing(t, ts, pairing.PairingID, signedClaimBody(t, pairing, key, "Phone", "ios"), http.StatusCreated)
	req := signedControllerRequest(t, ts, key, claim.Tokens.AccessToken, http.MethodPost, "/api/controller/presence", nil, time.Now(), randomControllerNonce(t))
	resp, err := ts.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	ts.post(t, admin.cookie, "/api/admin/controllers/"+claim.Controller.ID+"/revoke", http.StatusOK)

	rows := listAudit(t, ts, admin)
	login := findAudit(rows, "admin_login_succeeded")
	if login == nil || login.ActorKind != "admin" || login.ActorID != admin.id || login.ActorUA == "" {
		t.Fatalf("admin login must snapshot the acting session and browser: %#v", login)
	}
	paired := findAudit(rows, "controller_paired")
	if paired == nil || paired.ActorKind != "controller" || paired.ActorID != claim.Controller.ID || paired.ActorLabel != "Phone" {
		t.Fatalf("controller_paired must be attributed to the new controller: %#v", paired)
	}
	revoked := findAudit(rows, "controller_revoked")
	if revoked == nil || revoked.ActorKind != "admin" || revoked.ActorID != admin.id {
		t.Fatalf("controller_revoked is an admin action: %#v", revoked)
	}
	// Backfill: rows written before actor columns existed are attributed on start.
	if _, err := ts.db.Exec(`INSERT INTO audit_log(ts,event,ip,session_id,detail) VALUES(?,?,?,?,?)`,
		time.Now().Unix(), "controller_access_refreshed", "", "", `{"controller_id":"`+claim.Controller.ID+`"}`); err != nil {
		t.Fatal(err)
	}
	if _, err := ts.db.Exec(`INSERT INTO audit_log(ts,event,ip,session_id,detail) VALUES(?,?,?,?,?)`,
		time.Now().Unix(), "admin_logout", "", admin.id, ``); err != nil {
		t.Fatal(err)
	}
	if err := ts.relay.backfillAuditActors(context.Background()); err != nil {
		t.Fatal(err)
	}
	rows = listAudit(t, ts, admin)
	if refreshed := findAudit(rows, "controller_access_refreshed"); refreshed == nil || refreshed.ActorKind != "controller" || refreshed.ActorLabel != "Phone" {
		t.Fatalf("backfill must attribute legacy controller rows: %#v", refreshed)
	}
	if logout := findAudit(rows, "admin_logout"); logout == nil || logout.ActorKind != "admin" || logout.ActorUA == "" {
		t.Fatalf("backfill must attribute legacy admin rows from the live session: %#v", logout)
	}
}

func TestHistoryRetentionPurgesOnlyStaleTerminalRecords(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	ts.relay.cfg.HistoryRetention = 30 * 24 * time.Hour
	now := time.Now()
	old := now.Add(-31 * 24 * time.Hour).Unix()
	fresh := now.Add(-time.Hour).Unix()
	insertController := func(id, status string, revokedAt any) {
		t.Helper()
		if _, err := ts.db.Exec(`INSERT INTO controllers(id,name,platform,public_key_der,public_key_sha256,scopes_json,status,created_at,revoked_at)
VALUES(?,?,?,?,?,?,?,?,?)`, id, id, "ios", []byte{1}, id, `["screen.view"]`, status, old, revokedAt); err != nil {
			t.Fatal(err)
		}
	}
	insertController("ctl_stale", "revoked", old)
	insertController("ctl_recent", "revoked", fresh)
	insertController("ctl_live", "active", nil)
	insertEnrollment := func(id string, expiresAt int64, usedAt, revokedAt any) {
		t.Helper()
		if _, err := ts.db.Exec(`INSERT INTO enrollments(id,token_hash,expires_at,used_at,revoked_at,created_at) VALUES(?,?,?,?,?,?)`,
			id, id, expiresAt, usedAt, revokedAt, old); err != nil {
			t.Fatal(err)
		}
	}
	insertEnrollment("enroll_stale_expired", old, nil, nil)
	insertEnrollment("enroll_stale_used", neverExpiresUnix, old, nil)
	insertEnrollment("enroll_recent_revoked", neverExpiresUnix, nil, fresh)
	insertEnrollment("enroll_never_active", neverExpiresUnix, nil, nil)
	insertEnrollment("enroll_just_expired", now.Add(-time.Minute).Unix(), nil, nil)

	controllers, enrollments := ts.relay.applyHistoryRetention(context.Background(), now)
	if controllers != 1 || enrollments != 2 {
		t.Fatalf("purged controllers=%d enrollments=%d, want 1 and 2", controllers, enrollments)
	}
	var ids string
	if err := ts.db.QueryRow(`SELECT group_concat(id) FROM (SELECT id FROM controllers ORDER BY id)`).Scan(&ids); err != nil || ids != "ctl_live,ctl_recent" {
		t.Fatalf("controllers left=%q (%v)", ids, err)
	}
	var left int
	if err := ts.db.QueryRow(`SELECT count(*) FROM enrollments WHERE id IN ('enroll_recent_revoked','enroll_never_active','enroll_just_expired')`).Scan(&left); err != nil || left != 3 {
		t.Fatalf("recent/active enrollments must survive: %d (%v)", left, err)
	}
	var event string
	if err := ts.db.QueryRow(`SELECT actor_kind FROM audit_log WHERE event='history_retention_applied'`).Scan(&event); err != nil || event != "system" {
		t.Fatalf("retention must audit as system: %q (%v)", event, err)
	}
	ts.relay.cfg.HistoryRetention = 0
	if c, e := ts.relay.applyHistoryRetention(context.Background(), now.Add(365*24*time.Hour)); c != 0 || e != 0 {
		t.Fatalf("retention 0 must be a no-op: %d %d", c, e)
	}
}

func TestControllerClientProfileAndTelemetry(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	admin := ts.login(t)
	pairing := createPairingFixture(t, ts, admin, []string{"screen.view"})
	key := newControllerKey(t)
	claim := claimPairing(t, ts, pairing.PairingID, signedClaimBody(t, pairing, key, "Phone", "ios"), http.StatusCreated)
	id := claim.Controller.ID

	send := func(path string, body []byte, want int) {
		t.Helper()
		req := signedControllerRequest(t, ts, key, claim.Tokens.AccessToken, http.MethodPost, path, body, time.Now(), randomControllerNonce(t))
		req.Header.Set("User-Agent", "rctl/1.2 CFNetwork/1498 Darwin/23.4.0")
		resp, err := ts.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		payload, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != want {
			t.Fatalf("%s: status=%d want %d body=%s", path, resp.StatusCode, want, payload)
		}
	}
	profile := `{"client":{"model":"iPhone15,2","model_name":"iPhone 14 Pro","system_name":"iOS","system_version":"17.4",
		"app_version":"1.2.0","app_build":"57","device_name":"Grigorij's iPhone","locale":"ru_RU","timezone":"Europe/Moscow",
		"screen":"393×852 @3x","cpu_count":6,"memory_bytes":6144000000,"unknown_key":"dropped","idiom":"phone",
		"protocol_major":1,"schema_version":1,"install_channel":"debug","capabilities":["webrtc.screen","lan","webrtc.screen","relay"]}}`
	send("/api/controller/me/client", []byte(profile), http.StatusOK)
	row := findController(listControllers(t, ts, admin), id)
	if row == nil || row.Client["model"] != "iPhone15,2" || row.Client["cpu_count"] != float64(6) || row.Client["unknown_key"] != nil {
		t.Fatalf("client profile not stored as expected: %#v", row)
	}
	if caps, _ := row.Client["capabilities"].([]any); len(caps) != 3 || caps[0] != "lan" || caps[1] != "relay" || caps[2] != "webrtc.screen" {
		t.Fatalf("capabilities must be deduplicated and sorted: %#v", row.Client["capabilities"])
	}
	send("/api/controller/me/client", []byte(`{"client":{"capabilities":["<script>"]}}`), http.StatusBadRequest)
	if row.PairedIP == "" || row.LastIP == "" || row.UserAgent != "rctl/1.2 CFNetwork/1498 Darwin/23.4.0" || row.KeyFingerprint == "" {
		t.Fatalf("relay-observed facts missing: %#v", row)
	}
	// Bounded: an oversized known field is rejected and nothing changes.
	send("/api/controller/me/client", []byte(`{"client":{"model":"`+string(bytes.Repeat([]byte("x"), 65))+`"}}`), http.StatusBadRequest)
	send("/api/controller/me/client", []byte(`{"client":{"cpu_count":"six"}}`), http.StatusBadRequest)
	send("/api/controller/me/client", []byte(`{"client":{"model":"evil\n<script>"}}`), http.StatusBadRequest)
	if row = findController(listControllers(t, ts, admin), id); row.Client["model"] != "iPhone15,2" {
		t.Fatalf("rejected update must not touch the profile: %#v", row.Client)
	}

	// Telemetry rides on the heartbeat; an empty body is still a valid heartbeat.
	send("/api/controller/presence", []byte(`{"telemetry":{"battery_level":81,"battery_state":"charging","low_power":false,"network":"wifi","thermal":"nominal",
		"network_expensive":"true","lan_ip":"192.168.178.20","uptime_seconds":86400,"memory_available_bytes":1200000000}}`), http.StatusOK)
	row = findController(listControllers(t, ts, admin), id)
	if row.Telemetry["battery_level"] != float64(81) || row.Telemetry["low_power"] != false || row.Telemetry["network"] != "wifi" ||
		row.Telemetry["network_expensive"] != true || row.Telemetry["lan_ip"] != "192.168.178.20" || row.Telemetry["uptime_seconds"] != nil {
		t.Fatalf("telemetry not stored: %#v", row.Telemetry)
	}
	send("/api/controller/presence", []byte(`{"telemetry":{"lan_ip":"not-an-ip"}}`), http.StatusBadRequest)
	send("/api/controller/presence", []byte(`{"telemetry":{"low_power":"yes"}}`), http.StatusBadRequest)
	send("/api/controller/presence", nil, http.StatusOK)
	if row = findController(listControllers(t, ts, admin), id); row.Telemetry["battery_level"] != float64(81) {
		t.Fatalf("empty heartbeat must keep the last telemetry: %#v", row.Telemetry)
	}
	send("/api/controller/presence", []byte(`{"telemetry":{"battery_level":"full"}}`), http.StatusBadRequest)

	// Revoked controllers cannot update their profile.
	ts.post(t, admin.cookie, "/api/admin/controllers/"+id+"/revoke", http.StatusOK)
	send("/api/controller/me/client", []byte(profile), http.StatusUnauthorized)
}
