package setup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRecoveryRestoresInterruptedLifecycleBackup(t *testing.T) {
	installer, runner, database, _ := createUpgradeFixture(t)
	backup, err := (BackupManager{
		Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{},
		Now: func() time.Time { return time.Unix(1700010000, 0) },
	}).Create(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := beginRecovery(installer.Paths, "upgrade", backup, time.Unix(1700010100, 0)); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(database, []byte("partial-upgrade-state"), 0o600); err != nil {
		t.Fatal(err)
	}
	manager := RecoveryManager{Paths: installer.Paths, Runner: runner, Verifier: &sequenceVerifier{}}
	beforeCalls := len(runner.calls)
	state, err := manager.Plan()
	if err != nil || state.Operation != "upgrade" || state.Backup != backup || len(runner.calls) != beforeCalls {
		t.Fatalf("plan=%+v err=%v calls=%v", state, err, runner.calls[beforeCalls:])
	}
	state, err = manager.Recover(context.Background())
	if err != nil || state.Operation != "upgrade" {
		t.Fatalf("state=%+v err=%v", state, err)
	}
	if raw, err := os.ReadFile(database); err != nil || string(raw) != "persistent-device-state" {
		t.Fatalf("recovered state=%q err=%v", raw, err)
	}
	if _, err := os.Lstat(installer.Paths.RecoveryPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("recovery checkpoint remained: %v", err)
	}
}

func TestRecoveryRestartsInterruptedBackupAndCleansCandidate(t *testing.T) {
	installer, runner, _, _ := createUpgradeFixture(t)
	if err := beginRecovery(installer.Paths, "backup", "", time.Unix(1700010200, 0)); err != nil {
		t.Fatal(err)
	}
	candidate := filepath.Join(installer.Paths.BackupDir, ".backup-interrupted")
	if err := os.Mkdir(candidate, 0o700); err != nil {
		t.Fatal(err)
	}
	state, err := (RecoveryManager{Paths: installer.Paths, Runner: runner, Verifier: &sequenceVerifier{}}).Recover(context.Background())
	if err != nil || state.Operation != "backup" {
		t.Fatalf("state=%+v err=%v", state, err)
	}
	if _, err := os.Lstat(candidate); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("incomplete candidate remained: %v", err)
	}
	calls := strings.Join(runner.calls, "\n")
	if !strings.Contains(calls, " up -d") {
		t.Fatalf("services were not restarted:\n%s", calls)
	}
}

func TestPendingRecoveryBlocksNewLifecycleOperations(t *testing.T) {
	installer, runner, _, _ := createUpgradeFixture(t)
	if err := beginRecovery(installer.Paths, "backup", "", time.Unix(1700010300, 0)); err != nil {
		t.Fatal(err)
	}
	if _, err := (BackupManager{Paths: installer.Paths}).DryRun(); err == nil || !strings.Contains(err.Error(), "requires rctl-setup recover") {
		t.Fatalf("backup while recovery pending: %v", err)
	}
	if _, err := (UpgradeManager{Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{}, Now: time.Now}).Plan(upgradeOptions()); err == nil || !strings.Contains(err.Error(), "requires rctl-setup recover") {
		t.Fatalf("upgrade while recovery pending: %v", err)
	}
	if err := os.WriteFile(installer.Paths.RecoveryPath, []byte("not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := (RecoveryManager{Paths: installer.Paths}).Plan(); err == nil || !strings.Contains(err.Error(), "decode recovery checkpoint") {
		t.Fatalf("corrupt checkpoint result: %v", err)
	}
}

func TestRecoveryRemovesInterruptedFreshInstall(t *testing.T) {
	paths := PathsUnder(t.TempDir())
	if err := beginRecovery(paths, "install", "", time.Unix(1700010500, 0)); err != nil {
		t.Fatal(err)
	}
	for _, directory := range []string{paths.EtcDir, paths.OptDir, paths.DataDir, paths.BackupDir} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(paths.Compose, []byte("partial compose"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(paths.DataDir, "partial.db"), []byte("partial"), 0o600); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{}
	state, err := (RecoveryManager{Paths: paths, Runner: runner, Verifier: &sequenceVerifier{}}).Recover(context.Background())
	if err != nil || state.Operation != "install" {
		t.Fatalf("state=%+v err=%v", state, err)
	}
	for _, removed := range []string{paths.EtcDir, paths.OptDir, paths.DataDir, paths.BackupDir, paths.RecoveryPath} {
		if _, err := os.Lstat(removed); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("partial install path remained %s: %v", removed, err)
		}
	}
	if !strings.Contains(strings.Join(runner.calls, "\n"), " down --remove-orphans") {
		t.Fatal("partial compose project was not removed")
	}
}

func TestRecoveryCompletesInterruptedUninstalledRestore(t *testing.T) {
	installer, runner, database := createUninstallFixture(t)
	uninstall, err := (UninstallManager{
		Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{},
		Now: func() time.Time { return time.Unix(1700010600, 0) },
	}).Uninstall(context.Background(), UninstallOptions{KeepData: true})
	if err != nil {
		t.Fatal(err)
	}
	if err := beginRecovery(installer.Paths, "restore-uninstalled", uninstall.Backup, time.Unix(1700010700, 0)); err != nil {
		t.Fatal(err)
	}
	retained, err := reserveRetainedData(installer.Paths.DataDir)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(installer.Paths.OptDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(installer.Paths.Compose, []byte("partial compose"), 0o644); err != nil {
		t.Fatal(err)
	}
	state, err := (RecoveryManager{Paths: installer.Paths, Runner: runner, Verifier: &sequenceVerifier{}}).Recover(context.Background())
	if err != nil || state.Operation != "restore-uninstalled" {
		t.Fatalf("state=%+v err=%v", state, err)
	}
	if raw, err := os.ReadFile(database); err != nil || string(raw) != "persistent-state" {
		t.Fatalf("recovered database=%q err=%v", raw, err)
	}
	if _, err := os.Lstat(retained); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("superseded retained data remained: %v", err)
	}
	if _, err := loadManifest(installer.Paths.ManifestPath); err != nil {
		t.Fatalf("ownership was not recovered: %v", err)
	}
}
