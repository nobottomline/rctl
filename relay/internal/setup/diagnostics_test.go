package setup

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const tlsFailureFixture = `{"level":"error","logger":"tls.obtain","msg":"could not get certificate from issuer","error":"private.example: urn:ietf:params:acme:error:rateLimited retry https://private.example/secret-token","identifier":"private.example","request":{"Authorization":"Bearer secret-token"}}`

type diagnosticRunner struct {
	fakeRunner
	logFailure     bool
	paths          Paths
	readBeforeStop bool
	deadlineValid  bool
}

func (r *diagnosticRunner) Run(ctx context.Context, name string, args ...string) (string, error) {
	if strings.Contains(strings.Join(args, " "), " logs ") {
		r.calls = append(r.calls, name+" "+strings.Join(args, " "))
		_, err := os.Stat(r.paths.Compose)
		r.readBeforeStop = err == nil && !strings.Contains(strings.Join(r.calls, "\n"), " down --remove-orphans")
		deadline, ok := ctx.Deadline()
		r.deadlineValid = ok && time.Until(deadline) <= diagnosticTimeout && ctx.Err() == nil
		if r.logFailure {
			return "secret-token private.example", errors.New("secret-token")
		}
		return tlsFailureFixture, nil
	}
	return r.fakeRunner.Run(ctx, name, args...)
}

func TestFailedInstallPreservesPrivateBoundedDiagnosticsBeforeRollback(t *testing.T) {
	for _, logFailure := range []bool{false, true} {
		t.Run(map[bool]string{false: "logs", true: "log failure"}[logFailure], func(t *testing.T) {
			installer := testInstaller(t, nil, &fakeVerifier{err: errors.New("TLS probe failed")})
			runner := &diagnosticRunner{logFailure: logFailure, paths: installer.Paths}
			installer.Runner = runner
			_, err := installer.Install(context.Background(), validConfig(), InstallOptions{})
			if err == nil || !strings.Contains(err.Error(), "TLS probe failed") {
				t.Fatalf("original failure was lost: %v", err)
			}
			if !runner.readBeforeStop || !runner.deadlineValid {
				t.Fatalf("diagnostic ordering or deadline invalid: before=%v deadline=%v", runner.readBeforeStop, runner.deadlineValid)
			}
			files, err := filepath.Glob(filepath.Join(installer.Paths.LogDir, "failure-*.json"))
			if err != nil || len(files) != 1 {
				t.Fatalf("missing report: %v, %v", files, err)
			}
			raw, err := os.ReadFile(files[0])
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(raw), "secret-token") || strings.Contains(string(raw), "private.example") {
				t.Fatal("diagnostics retained raw private log fields")
			}
			info, err := os.Stat(files[0])
			if err != nil || info.Mode().Perm() != 0o600 {
				t.Fatalf("unsafe report permissions: %v", err)
			}
			var report failureDiagnostics
			if err := json.Unmarshal(raw, &report); err != nil {
				t.Fatal(err)
			}
			if report.Stage != "public_https" || len(report.Services) != 3 {
				t.Fatalf("incomplete diagnostic context: %+v", report)
			}
			if logFailure {
				if report.LogRead != "command_failed" || len(report.Events) != 0 {
					t.Fatal("failed collection was not recorded")
				}
			} else if len(report.Events) != 1 || report.Events[0].Signals[0] != "acme:rateLimited" {
				t.Fatal("ACME failure signal lost")
			}
			if _, err := pendingRecovery(installer.Paths); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("diagnostics prevented successful rollback: %v", err)
			}
		})
	}
}

func TestTLSDiagnosticsDiscardUnknownFieldsAndBoundInput(t *testing.T) {
	raw := strings.Join([]string{
		"plain text secret-token",
		`{"logger":"http.log.access","level":"error","msg":"secret-token"}`,
		`{"logger":"tls.private.example","level":"secret-token","msg":"secret-token","error":"secret-token"}`,
		tlsFailureFixture,
	}, "\n")
	events := summarizeTLSLogs(raw)
	if len(events) != 2 || events[0].Event != "unknown" || events[0].Level != "unknown" {
		t.Fatalf("unexpected TLS projection: %+v", events)
	}
	encoded, err := json.Marshal(events)
	if err != nil || strings.Contains(string(encoded), "secret-token") || strings.Contains(string(encoded), "private.example") {
		t.Fatal("projection leaked arbitrary strings")
	}
	if got := len(summarizeTLSLogs(strings.Repeat(tlsFailureFixture+"\n", 300))); got != 200 {
		t.Fatalf("unbounded event count: %d", got)
	}
	if got := len(summarizeTLSLogs(strings.Repeat("x", 100000) + "\n" + tlsFailureFixture)); got != 0 {
		t.Fatalf("oversized log line accepted: %d", got)
	}
	if diagnosticEnum("secret-token", "running") != "unknown" {
		t.Fatal("service state projection accepted arbitrary text")
	}
}

func TestFailureDiagnosticsRejectSymlinkedLogDirectory(t *testing.T) {
	runner := &fakeRunner{}
	installer := testInstaller(t, runner, &fakeVerifier{})
	target := t.TempDir()
	if err := os.MkdirAll(filepath.Dir(installer.Paths.LogDir), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, installer.Paths.LogDir); err != nil {
		t.Fatal(err)
	}
	installer.saveFailureDiagnostics("public_https")
	if len(runner.calls) != 0 {
		t.Fatal("collected logs with unsafe destination")
	}
	entries, err := os.ReadDir(target)
	if err != nil || len(entries) != 0 {
		t.Fatal("wrote through symlinked diagnostic directory")
	}
}

func TestSuccessfulInstallDoesNotCollectFailureDiagnostics(t *testing.T) {
	runner := &fakeRunner{}
	installer := testInstaller(t, runner, &fakeVerifier{})
	if _, err := installer.Install(context.Background(), validConfig(), InstallOptions{}); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(strings.Join(runner.calls, "\n"), " logs ") {
		t.Fatal("successful installation collected logs")
	}
}
