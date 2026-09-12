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

func TestFailedFreshRollbackRetainsRecoveryAndManagedFiles(t *testing.T) {
	runner := &fakeRunner{failContains: " down --remove-orphans"}
	installer := testInstaller(t, runner, &fakeVerifier{err: errors.New("TLS verification failed")})
	_, err := installer.Install(context.Background(), validConfig(), InstallOptions{})
	if err == nil || !strings.Contains(err.Error(), "automatic rollback incomplete") {
		t.Fatalf("install failure = %v", err)
	}
	assertPendingInstall(t, installer.Paths)
	raw, err := os.ReadFile(filepath.Join(installer.Paths.LogDir, "install-1700000000.json"))
	if err != nil {
		t.Fatal(err)
	}
	var journal Journal
	if err := json.Unmarshal(raw, &journal); err != nil || journal.Status != "rollback_failed" {
		t.Fatalf("journal status = %q, error = %v", journal.Status, err)
	}
	before := len(runner.calls)
	if _, err := installer.Install(context.Background(), validConfig(), InstallOptions{}); err == nil || !strings.Contains(err.Error(), "requires rctl-setup recover") {
		t.Fatalf("retry with pending rollback = %v", err)
	}
	if len(runner.calls) != before {
		t.Fatal("blocked install ran container commands")
	}
	manager := RecoveryManager{Paths: installer.Paths, Runner: runner}
	if _, err := manager.Recover(context.Background()); err == nil {
		t.Fatal("recovery ignored stop failure")
	}
	assertPendingInstall(t, installer.Paths)
	runner.failContains = ""
	if _, err := manager.Recover(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{installer.Paths.RecoveryPath, installer.Paths.EtcDir, installer.Paths.OptDir, installer.Paths.DataDir} {
		if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("recovery retained %s: %v", path, err)
		}
	}
}

func assertPendingInstall(t *testing.T, paths Paths) {
	t.Helper()
	if state, err := pendingRecovery(paths); err != nil || state.Operation != "install" {
		t.Fatalf("pending install = %+v, %v", state, err)
	}
	for _, path := range []string{paths.Compose, paths.RelayEnv, paths.CaddyDataDir} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("failed stop removed %s: %v", path, err)
		}
	}
}

func TestRecoveryDoesNotReplaceDataWhenStopFails(t *testing.T) {
	installer, runner, database, _ := createUpgradeFixture(t)
	backup, err := (BackupManager{Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{}, Now: installer.Now}).Create(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := beginRecovery(installer.Paths, "upgrade", backup, installer.Now()); err != nil {
		t.Fatal(err)
	}
	const current = "live state must not be replaced"
	if err := os.WriteFile(database, []byte(current), 0o600); err != nil {
		t.Fatal(err)
	}
	runner.failContains = " down --remove-orphans"
	if _, err := (RecoveryManager{Paths: installer.Paths, Runner: runner}).Recover(context.Background()); err == nil {
		t.Fatal("expected stop failure")
	}
	if raw, err := os.ReadFile(database); err != nil || string(raw) != current {
		t.Fatalf("live data replaced: error=%v", err)
	}
	if _, err := pendingRecovery(installer.Paths); err != nil {
		t.Fatalf("checkpoint lost: %v", err)
	}
}

func TestStopFreshServicesRejectsNonRegularCompose(t *testing.T) {
	for _, kind := range []string{"directory", "symlink"} {
		t.Run(kind, func(t *testing.T) {
			runner := &fakeRunner{}
			installer := testInstaller(t, runner, &fakeVerifier{})
			if err := os.MkdirAll(installer.Paths.OptDir, 0o755); err != nil {
				t.Fatal(err)
			}
			var err error
			if kind == "directory" {
				err = os.Mkdir(installer.Paths.Compose, 0o700)
			} else {
				err = os.Symlink("missing", installer.Paths.Compose)
			}
			if err != nil {
				t.Fatal(err)
			}
			if err := installer.stopFreshServices(context.Background()); err == nil || len(runner.calls) != 0 {
				t.Fatalf("unsafe Compose accepted: %v", err)
			}
		})
	}
}

func TestInterruptedInstallCleanupReportsFilesystemFailure(t *testing.T) {
	paths := PathsUnder(t.TempDir())
	if err := beginRecovery(paths, "install", "", time.Unix(1700000000, 0)); err != nil {
		t.Fatal(err)
	}
	// A nonempty directory cannot be removed as a package-owned regular file.
	if err := os.MkdirAll(filepath.Join(paths.RelayEnv, "child"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := (RecoveryManager{Paths: paths, Runner: &fakeRunner{}}).Recover(context.Background()); err == nil {
		t.Fatal("cleanup failure was ignored")
	}
	if _, err := pendingRecovery(paths); err != nil {
		t.Fatalf("checkpoint lost after cleanup failure: %v", err)
	}
}

type cancelOnStartRunner struct {
	fakeRunner
	cancel         context.CancelFunc
	stopContextErr error
}

func (r *cancelOnStartRunner) Run(ctx context.Context, name string, args ...string) (string, error) {
	call := strings.Join(args, " ")
	if strings.Contains(call, " up -d") {
		r.cancel()
		return "", ctx.Err()
	}
	if strings.Contains(call, " down --remove-orphans") {
		r.stopContextErr = ctx.Err()
	}
	return r.fakeRunner.Run(ctx, name, args...)
}

func TestCancelledInstallUsesIndependentRollbackContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runner := &cancelOnStartRunner{cancel: cancel}
	installer := testInstaller(t, nil, &fakeVerifier{})
	installer.Runner = runner
	if _, err := installer.Install(ctx, validConfig(), InstallOptions{}); err == nil {
		t.Fatal("expected cancellation")
	}
	if runner.stopContextErr != nil || !strings.Contains(strings.Join(runner.calls, "\n"), " down --remove-orphans") {
		t.Fatalf("rollback did not use a live context: %v", runner.stopContextErr)
	}
	if _, err := pendingRecovery(installer.Paths); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("successful rollback retained checkpoint: %v", err)
	}
}
