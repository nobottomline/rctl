package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nobottomline/rctl/relay/internal/qualification"
)

func TestRunVerifiesExactReportAndDigest(t *testing.T) {
	commit := strings.Repeat("a", 40)
	checksums := strings.Repeat("b", 64)
	image := "ghcr.io/nobottomline/rctl-relay@sha256:" + strings.Repeat("c", 64)
	raw := []byte(`{
  "schema": 1,
  "product": "rctl",
  "tag": "v1.2.3",
  "version": "1.2.3",
  "source_sha": "` + commit + `",
  "relay_image": "` + image + `",
  "checksums_sha256": "` + checksums + `",
  "deployment_profile": "dedicated-domain",
  "completed_at": "` + time.Now().UTC().Format(time.RFC3339) + `",
  "checks": {
    "bootstrap": true, "acme": true, "https_wss": true,
    "turn_udp": true, "turn_tcp": true, "forced_turn": true,
    "device_enrollment": true, "relay_control": true, "lan_control": true,
    "relay_restart": true, "backup_restore": true, "upgrade_rollback": true,
    "reset_admin": true, "interrupted_recovery": true,
    "uninstall_keep_data": true, "uninstall_delete_data": true
  }
}`)
	path := filepath.Join(t.TempDir(), "report.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	args := []string{
		"--file", path, "--tag", "v1.2.3", "--source-sha", commit,
		"--relay-image", image, "--checksums-sha256", checksums,
		"--report-sha256", qualification.Digest(raw),
	}
	var output, errorOutput bytes.Buffer
	if code := run(args, &output, &errorOutput); code != 0 || output.String() != "qualification report verified\n" || errorOutput.Len() != 0 {
		t.Fatalf("code=%d output=%q error=%q", code, output.String(), errorOutput.String())
	}

	wrong := sha256.Sum256([]byte("different"))
	args[len(args)-1] = hex.EncodeToString(wrong[:])
	output.Reset()
	errorOutput.Reset()
	if code := run(args, &output, &errorOutput); code != 1 || !strings.Contains(errorOutput.String(), "report digest does not match") {
		t.Fatalf("code=%d output=%q error=%q", code, output.String(), errorOutput.String())
	}
}

func TestRunRejectsIncompleteArguments(t *testing.T) {
	var output, errorOutput bytes.Buffer
	if code := run([]string{"unexpected"}, &output, &errorOutput); code != 2 || !strings.Contains(errorOutput.String(), "required") {
		t.Fatalf("code=%d error=%q", code, errorOutput.String())
	}
}
