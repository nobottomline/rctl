package relay

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func TestDeviceUpdateUsesExactPackageVersion(t *testing.T) {
	dc := deviceConn{daemonVersion: "0.4.0", packageVersion: "0.4.0~rc.1"}
	if dc.updateVersion() != "0.4.0~rc.1" {
		t.Fatal("candidate was mistaken for stable")
	}
	dc.packageVersion = ""
	if dc.updateVersion() != "0.4.0" {
		t.Fatal("legacy version fallback changed")
	}
}

func TestDeviceUpdatePreflightRejectsBeforeStartingTransaction(t *testing.T) {
	for _, tc := range []struct {
		name       string
		configured bool
		online     bool
		approved   bool
		features   []string
		version    string
		status     int
		errorCode  string
	}{
		{"channel off", false, true, true, []string{"update.transactional"}, "0.3.0", http.StatusServiceUnavailable, "update_manifest_not_configured"},
		{"offline", true, false, true, nil, "0.3.0", http.StatusNotFound, "device_offline"},
		{"not approved", true, true, false, []string{"update.transactional"}, "0.3.0", http.StatusForbidden, "device_not_approved"},
		{"legacy without features", true, true, true, nil, "0.3.0", http.StatusConflict, "device_updater_not_supported"},
		{"rootless without updater", true, true, true, []string{"screen.webrtc", "destructive.confirmation"}, "0.3.0", http.StatusConflict, "device_updater_not_supported"},
		{"rootless without its catalog", true, true, true, []string{"update.transactional", "update.transactional.rootless"}, "0.3.0", http.StatusServiceUnavailable, "update_manifest_not_configured"},
		{"already current", true, true, true, []string{"update.transactional"}, "0.3.1", http.StatusConflict, "device_already_current"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			db, err := sql.Open("sqlite", ":memory:")
			if err != nil {
				t.Fatal(err)
			}
			db.SetMaxOpenConns(1)
			t.Cleanup(func() { _ = db.Close() })
			s := &server{
				cfg: config{
					UpdateTargetVersion: "0.3.1",
				},
				db:      db,
				devices: make(map[string]*deviceConn),
			}
			if tc.configured {
				s.cfg.UpdateManifestURL = "https://releases.example.test/rctl-update-stable.json"
			}
			if err := s.migrate(context.Background()); err != nil {
				t.Fatal(err)
			}
			now := time.Now().Unix()
			approval := "pending"
			if tc.approved {
				approval = "approved"
			}
			if _, err := db.Exec(`INSERT INTO devices(id, name, status, created_at, updated_at) VALUES(?, ?, ?, ?, ?)`, "device-1", "iPad", approval, now, now); err != nil {
				t.Fatal(err)
			}
			if tc.online {
				// No WebSocket is attached: reaching confirmation/installation is a test failure.
				s.devices["device-1"] = &deviceConn{
					id: "device-1", daemonVersion: tc.version, features: tc.features,
				}
			}
			recorder := httptest.NewRecorder()
			request := httptest.NewRequest(http.MethodPost, "/api/admin/devices/device-1/update", nil)
			request.SetPathValue("id", "device-1")
			s.handleUpdateDevice(recorder, request)
			if recorder.Code != tc.status {
				t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
			}
			var body struct {
				Error string `json:"error"`
			}
			if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if body.Error != tc.errorCode {
				t.Fatalf("error=%q, want %q", body.Error, tc.errorCode)
			}
		})
	}
}
