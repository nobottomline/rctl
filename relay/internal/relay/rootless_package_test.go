package relay

import (
	"github.com/nobottomline/rctl/relay/internal/deb"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPackageArchitectureSelection(t *testing.T) {
	for _, scenario := range []struct {
		name, architecture string
		rootful, rootless  bool
		status             int
	}{
		{"legacy", "", true, true, 201},
		{"rootful", "iphoneos-arm", true, true, 201},
		{"rootless", "iphoneos-arm64", true, true, 201},
		{"rootless only", "iphoneos-arm64", false, true, 201},
		{"missing rootless", "iphoneos-arm64", true, false, 503},
		{"no implicit rootless", "", false, true, 503},
		{"unsupported", "arm64e", true, true, 400},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			s := newPackageTestServer(t)
			if !scenario.rootful {
				s.publicPackage = nil
			}
			if scenario.rootless {
				s.rootlessPackage = architecturePackageFixture(t, "iphoneos-arm64")
				s.rootlessPackageInfo, _ = deb.Inspect(s.rootlessPackage)
			}
			recorder := httptest.NewRecorder()
			s.handleCreateDevicePackage(recorder, httptest.NewRequest(http.MethodPost, "/api/admin/device-package", strings.NewReader(`{"architecture":"`+scenario.architecture+`"}`)))
			if recorder.Code != scenario.status {
				t.Fatalf("status=%d wanted=%d body=%s", recorder.Code, scenario.status, recorder.Body.String())
			}
			var count int
			if err := s.db.QueryRow(`SELECT count(*) FROM enrollments`).Scan(&count); err != nil {
				t.Fatal(err)
			}
			if scenario.status == 201 {
				arch := scenario.architecture
				if arch == "" {
					arch = "iphoneos-arm"
				}
				if !strings.Contains(recorder.Header().Get("Content-Disposition"), "_"+arch+".deb") || count != 1 {
					t.Fatal("wrong package or enrollment")
				}
			} else if count != 0 {
				t.Fatal("rejected request created an enrollment")
			}
			expected := 0
			if scenario.rootful {
				expected++
			}
			if scenario.rootless {
				expected++
			}
			if len(s.devicePackageOptions()) != expected {
				t.Fatal("wrong advertised package variants")
			}
		})
	}
}
