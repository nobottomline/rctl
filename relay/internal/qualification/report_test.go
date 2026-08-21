package qualification

import (
	"os"
	"path/filepath"
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
		Bootstrap: true, ACME: true, HTTPSWSS: true, TURNUDP: true, TURNTCP: true,
		ForcedTURN: true, DeviceEnrollment: true, RelayControl: true, LANControl: true,
		RelayRestart: true, BackupRestore: true, UpgradeRollback: true, ResetAdmin: true,
		InterruptedRecovery: true, UninstallKeepData: true, UninstallDeleteData: true,
	}
	return Report{
		Schema: 1, Product: "rctl", Tag: "v1.2.3", Version: "1.2.3", SourceSHA: commit,
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
		{"failed", func(r *Report, _ *Expected) { r.Checks.ForcedTURN = false }, "forced_turn"},
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
