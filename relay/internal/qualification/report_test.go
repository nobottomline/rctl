package qualification

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

func validReport() (Report, Expected) {
	now := time.Date(2026, 8, 21, 20, 0, 0, 0, time.UTC)
	commit := strings.Repeat("a", 40)
	digest := strings.Repeat("b", 64)
	image := "ghcr.io/nobottomline/rctl-relay@sha256:" + strings.Repeat("c", 64)
	checks := Checks{
		Bootstrap: true, BootstrapIdempotent: true, ACME: true, ACMERenewal: true,
		HTTPSWSS: true, TURNUDP: true, TURNTCP: true, ForcedTURN: true,
		PackagePersonalization: true, DeviceEnrollment: true, RelayControl: true, LANControl: true,
		RelayRestart: true, Doctor: true, BackupRestore: true, RelayUpgrade: true,
		UpgradeRollback: true, ResetAdmin: true, InterruptedRecovery: true,
		DeviceUpdate: true, DeviceUpdateRollback: true, PackageManagerUpgrade: true, PackageManagerRecovery: true,
		UninstallKeepData: true, UninstallDeleteData: true,
	}
	return Report{
		Schema: ReportSchema, Product: "rctl", Tag: "v1.2.3", Version: "1.2.3", SourceSHA: commit,
		RelayImage: image, ChecksumsSHA256: digest, DeploymentProfile: "dedicated-domain",
		CompletedAt: now.Add(-time.Hour).Format(time.RFC3339), Checks: checks,
	}, Expected{Tag: "v1.2.3", SourceSHA: commit, RelayImage: image, ChecksumsSHA256: digest, Now: now}
}

func TestValidateAcceptsBoundExactQualification(t *testing.T) {
	report, expected := validReport()
	if err := Validate(report, expected); err != nil {
		t.Fatal(err)
	}
}

func TestValidateRejectsIdentityFreshnessAndIncompleteChecks(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*Report, *Expected)
		want   string
	}{
		{"tag", func(r *Report, _ *Expected) { r.Tag = "v1.2.4" }, "release identity"},
		{"source", func(r *Report, _ *Expected) { r.SourceSHA = strings.Repeat("d", 40) }, "source commit"},
		{"image", func(r *Report, _ *Expected) { r.RelayImage += "-changed" }, "relay image"},
		{"checksums", func(r *Report, _ *Expected) { r.ChecksumsSHA256 = strings.Repeat("e", 64) }, "checksum-set"},
		{"profile", func(r *Report, _ *Expected) { r.DeploymentProfile = "bare-ip" }, "deployment profile"},
		{"stale", func(r *Report, e *Expected) { r.CompletedAt = e.Now.Add(-31 * 24 * time.Hour).Format(time.RFC3339) }, "publication window"},
		{"future", func(r *Report, e *Expected) { r.CompletedAt = e.Now.Add(6 * time.Minute).Format(time.RFC3339) }, "publication window"},
		{"schema", func(r *Report, _ *Expected) { r.Schema-- }, "incompatible"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			report, expected := validReport()
			test.mutate(&report, &expected)
			if err := Validate(report, expected); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("validation error=%v, want %q", err, test.want)
			}
		})
	}
}

func TestValidateRejectsEveryIncompleteCheck(t *testing.T) {
	report, expected := validReport()
	checks := &report.Checks
	tests := []struct {
		name  string
		field *bool
	}{
		{"bootstrap", &checks.Bootstrap}, {"bootstrap_idempotent", &checks.BootstrapIdempotent},
		{"acme", &checks.ACME}, {"acme_renewal", &checks.ACMERenewal}, {"https_wss", &checks.HTTPSWSS},
		{"turn_udp", &checks.TURNUDP}, {"turn_tcp", &checks.TURNTCP}, {"forced_turn", &checks.ForcedTURN},
		{"package_personalization", &checks.PackagePersonalization}, {"device_enrollment", &checks.DeviceEnrollment},
		{"relay_control", &checks.RelayControl}, {"lan_control", &checks.LANControl},
		{"relay_restart", &checks.RelayRestart}, {"doctor", &checks.Doctor},
		{"backup_restore", &checks.BackupRestore}, {"relay_upgrade", &checks.RelayUpgrade},
		{"upgrade_rollback", &checks.UpgradeRollback}, {"reset_admin", &checks.ResetAdmin},
		{"interrupted_recovery", &checks.InterruptedRecovery}, {"device_update", &checks.DeviceUpdate},
		{"device_update_rollback", &checks.DeviceUpdateRollback}, {"package_manager_upgrade", &checks.PackageManagerUpgrade},
		{"package_manager_recovery", &checks.PackageManagerRecovery}, {"uninstall_keep_data", &checks.UninstallKeepData},
		{"uninstall_delete_data", &checks.UninstallDeleteData},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			*test.field = false
			defer func() { *test.field = true }()
			if err := Validate(report, expected); err == nil || !strings.Contains(err.Error(), test.name) {
				t.Fatalf("validation error=%v, want incomplete %q", err, test.name)
			}
		})
	}
}

func TestFailedChecksCoversEverySchemaField(t *testing.T) {
	raw, err := json.Marshal(Checks{})
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]bool
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}
	got := failedChecks(Checks{})
	want := make([]string, 0, len(fields))
	for name := range fields {
		want = append(want, name)
	}
	sort.Strings(got)
	sort.Strings(want)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("failed-check coverage=%v, schema fields=%v", got, want)
	}
}

func TestLoadRejectsUnknownTrailingAndSymlinkReports(t *testing.T) {
	directory := t.TempDir()
	unknown := filepath.Join(directory, "unknown.json")
	if err := os.WriteFile(unknown, []byte(`{"schema":1,"unknown":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := Load(unknown); err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("unknown field result: %v", err)
	}
	trailing := filepath.Join(directory, "trailing.json")
	if err := os.WriteFile(trailing, []byte(`{} {}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := Load(trailing); err == nil || !strings.Contains(err.Error(), "trailing") {
		t.Fatalf("trailing result: %v", err)
	}
	link := filepath.Join(directory, "link.json")
	if err := os.Symlink(unknown, link); err != nil {
		t.Fatal(err)
	}
	if _, _, err := Load(link); err == nil || !strings.Contains(err.Error(), "regular file") {
		t.Fatalf("symlink result: %v", err)
	}
}
