package relay

import (
	"context"
	"net/http"
	"testing"
	"time"
)

func TestAdminDeleteDevice(t *testing.T) {
	ts := newAdminSessionTestServer(t)
	now := time.Now().Unix()
	if _, err := ts.db.ExecContext(context.Background(),
		`INSERT INTO devices(id, name, status, created_at, updated_at, revoked_at) VALUES(?, ?, ?, ?, ?, ?)`,
		"stale-device", "stale", "revoked", now, now, now,
	); err != nil {
		t.Fatal(err)
	}

	session := ts.login(t)
	ts.post(t, session.cookie, "/api/admin/devices/stale-device/delete", http.StatusOK)

	var count int
	if err := ts.db.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM devices WHERE id=?`, "stale-device").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("device count after delete = %d, want 0", count)
	}
	ts.post(t, session.cookie, "/api/admin/devices/stale-device/delete", http.StatusNotFound)
}
