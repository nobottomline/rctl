package qualification

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"time"
)

const maxReportBytes = 1 << 20

var (
	versionPattern = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)
	commitPattern  = regexp.MustCompile(`^[0-9a-f]{40}$`)
	digestPattern  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	imagePattern   = regexp.MustCompile(`^ghcr\.io/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$`)
)

type Checks struct {
	Bootstrap           bool `json:"bootstrap"`
	ACME                bool `json:"acme"`
	HTTPSWSS            bool `json:"https_wss"`
	TURNUDP             bool `json:"turn_udp"`
	TURNTCP             bool `json:"turn_tcp"`
	ForcedTURN          bool `json:"forced_turn"`
	DeviceEnrollment    bool `json:"device_enrollment"`
	RelayControl        bool `json:"relay_control"`
	LANControl          bool `json:"lan_control"`
	RelayRestart        bool `json:"relay_restart"`
	BackupRestore       bool `json:"backup_restore"`
	UpgradeRollback     bool `json:"upgrade_rollback"`
	ResetAdmin          bool `json:"reset_admin"`
	InterruptedRecovery bool `json:"interrupted_recovery"`
	UninstallKeepData   bool `json:"uninstall_keep_data"`
	UninstallDeleteData bool `json:"uninstall_delete_data"`
}

type Report struct {
	Schema            int    `json:"schema"`
	Product           string `json:"product"`
	Tag               string `json:"tag"`
	Version           string `json:"version"`
	SourceSHA         string `json:"source_sha"`
	RelayImage        string `json:"relay_image"`
	ChecksumsSHA256   string `json:"checksums_sha256"`
	DeploymentProfile string `json:"deployment_profile"`
	CompletedAt       string `json:"completed_at"`
	Checks            Checks `json:"checks"`
}

type Expected struct {
	Tag             string
	SourceSHA       string
	RelayImage      string
	ChecksumsSHA256 string
	Now             time.Time
}

func Load(path string) (Report, []byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return Report{}, nil, err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Size() < 1 || info.Size() > maxReportBytes {
		return Report{}, nil, errors.New("qualification report must be a bounded regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return Report{}, nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return Report{}, nil, err
	}
	if !opened.Mode().IsRegular() || !os.SameFile(info, opened) {
		return Report{}, nil, errors.New("qualification report changed while it was opened")
	}
	raw, err := io.ReadAll(io.LimitReader(file, maxReportBytes+1))
	if err != nil {
		return Report{}, nil, err
	}
	if len(raw) == 0 || len(raw) > maxReportBytes {
		return Report{}, nil, errors.New("qualification report must be a bounded regular file")
	}
	var report Report
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&report); err != nil {
		return Report{}, nil, fmt.Errorf("decode qualification report: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return Report{}, nil, errors.New("qualification report contains trailing data")
	}
	return report, raw, nil
}

func Validate(report Report, expected Expected) error {
	if expected.Now.IsZero() {
		expected.Now = time.Now()
	}
	if report.Schema != 1 || report.Product != "rctl" {
		return errors.New("qualification report is incompatible")
	}
	if !strings.HasPrefix(expected.Tag, "v") || !versionPattern.MatchString(strings.TrimPrefix(expected.Tag, "v")) {
		return errors.New("expected release tag is invalid")
	}
	if report.Tag != expected.Tag || report.Version != strings.TrimPrefix(expected.Tag, "v") {
		return errors.New("qualification report release identity does not match")
	}
	if !commitPattern.MatchString(expected.SourceSHA) || report.SourceSHA != expected.SourceSHA {
		return errors.New("qualification report source commit does not match")
	}
	if !imagePattern.MatchString(expected.RelayImage) || report.RelayImage != expected.RelayImage {
		return errors.New("qualification report relay image does not match")
	}
	if !digestPattern.MatchString(expected.ChecksumsSHA256) || report.ChecksumsSHA256 != expected.ChecksumsSHA256 {
		return errors.New("qualification report checksum-set digest does not match")
	}
	if report.DeploymentProfile != "dedicated-domain" {
		return errors.New("qualification report has an unsupported deployment profile")
	}
	completed, err := time.Parse(time.RFC3339, report.CompletedAt)
	if err != nil {
		return errors.New("qualification report completion time is invalid")
	}
	if completed.After(expected.Now.Add(5*time.Minute)) || completed.Before(expected.Now.Add(-30*24*time.Hour)) {
		return errors.New("qualification report is outside the accepted publication window")
	}
	missing := failedChecks(report.Checks)
	if len(missing) != 0 {
		return fmt.Errorf("qualification report has incomplete checks: %s", strings.Join(missing, ", "))
	}
	return nil
}

func Digest(raw []byte) string {
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func failedChecks(checks Checks) []string {
	values := []struct {
		name string
		pass bool
	}{
		{"bootstrap", checks.Bootstrap}, {"acme", checks.ACME}, {"https_wss", checks.HTTPSWSS},
		{"turn_udp", checks.TURNUDP}, {"turn_tcp", checks.TURNTCP}, {"forced_turn", checks.ForcedTURN},
		{"device_enrollment", checks.DeviceEnrollment}, {"relay_control", checks.RelayControl},
		{"lan_control", checks.LANControl}, {"relay_restart", checks.RelayRestart},
		{"backup_restore", checks.BackupRestore}, {"upgrade_rollback", checks.UpgradeRollback},
		{"reset_admin", checks.ResetAdmin}, {"interrupted_recovery", checks.InterruptedRecovery},
		{"uninstall_keep_data", checks.UninstallKeepData}, {"uninstall_delete_data", checks.UninstallDeleteData},
	}
	missing := make([]string, 0)
	for _, value := range values {
		if !value.pass {
			missing = append(missing, value.name)
		}
	}
	return missing
}
