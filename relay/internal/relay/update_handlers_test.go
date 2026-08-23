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

func TestDeviceUpdateRejectsAlreadyCurrentVersionBeforeStartingTransaction(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })
	s := &server{
		cfg: config{
			UpdateManifestURL:   "https://github.com/nobottomline/rctl/releases/latest/download/rctl-update-stable.json",
			UpdateTargetVersion: "0.3.1",
		},
		db:      db,
		devices: make(map[string]*deviceConn),
	}
	if err := s.migrate(context.Background()); err != nil {
		t.Fatal(err)
	}
	now := time.Now().Unix()
	if _, err := db.Exec(`INSERT INTO devices(id, name, status, created_at, updated_at) VALUES(?, ?, 'approved', ?, ?)`, "device-1", "iPad", now, now); err != nil {
		t.Fatal(err)
	}
	s.devices["device-1"] = &deviceConn{
		id: "device-1", daemonVersion: "0.3.1", features: []string{"update.transactional"},
	}
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/api/admin/devices/device-1/update", nil)
	request.SetPathValue("id", "device-1")
	s.handleUpdateDevice(recorder, request)
	if recorder.Code != http.StatusConflict {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}
