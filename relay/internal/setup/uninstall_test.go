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

func createUninstallFixture(t *testing.T) (Installer, *fakeRunner, string) {
	t.Helper()
	runner := &fakeRunner{}
	installer := testInstaller(t, runner, &fakeVerifier{})
	cfg := validConfig()
	cfg.Release = "1.2.3"
	if _, err := installer.Install(context.Background(), cfg, InstallOptions{Version: "1.2.3"}); err != nil {
		t.Fatal(err)
	}
	database := filepath.Join(installer.Paths.RelayDataDir, "rctl-relay.db")
	if err := os.WriteFile(database, []byte("persistent-state"), 0o600); err != nil {
		t.Fatal(err)
	}
	return installer, runner, database
}

func TestUninstallKeepDataPreservesStateAndRecoveryBackup(t *testing.T) {
	installer, runner, database := createUninstallFixture(t)
	manager := UninstallManager{
		Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{},
		Now: func() time.Time { return time.Unix(1700004000, 0) },
	}
	beforeCalls := len(runner.calls)
	plan, err := manager.Plan(UninstallOptions{DryRun: true, KeepData: true})
	if err != nil || !plan.DryRun || len(runner.calls) != beforeCalls {
		t.Fatalf("plan=%+v err=%v calls=%v", plan, err, runner.calls[beforeCalls:])
	}
	result, err := manager.Uninstall(context.Background(), UninstallOptions{KeepData: true})
	if err != nil {
		t.Fatal(err)
	}
	if !result.KeepData || result.Backup == "" {
		t.Fatalf("unexpected result: %+v", result)
	}
	if _, err := ValidateBackup(result.Backup); err != nil {
		t.Fatalf("recovery backup: %v", err)
	}
	if raw, err := os.ReadFile(database); err != nil || string(raw) != "persistent-state" {
		t.Fatalf("preserved database=%q err=%v", raw, err)
	}
	for _, removed := range []string{installer.Paths.ManifestPath, installer.Paths.RelayEnv, installer.Paths.Compose, installer.Paths.Caddyfile, installer.Paths.Coturn} {
		if _, err := os.Lstat(removed); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("owned file remained %s: %v", removed, err)
		}
	}
	if !strings.Contains(strings.Join(runner.calls, "\n"), " down --remove-orphans") {
		t.Fatal("compose project was not removed")
	}
}

func TestUninstallDeleteDataKeepsOnlyRecoveryMaterial(t *testing.T) {
	installer, runner, _ := createUninstallFixture(t)
	result, err := (UninstallManager{
		Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{},
		Now: func() time.Time { return time.Unix(1700005000, 0) },
	}).Uninstall(context.Background(), UninstallOptions{DeleteData: true})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(installer.Paths.DataDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("data directory remained: %v", err)
	}
	if _, err := ValidateBackup(result.Backup); err != nil {
		t.Fatalf("recovery backup: %v", err)
	}
	if _, err := os.Stat(installer.Paths.BackupDir); err != nil {
		t.Fatalf("backup directory was removed: %v", err)
	}
}

func TestUninstallDownFailureDoesNotRemoveOwnedState(t *testing.T) {
	installer, runner, database := createUninstallFixture(t)
	runner.failContains = " down --remove-orphans"
	manager := UninstallManager{
		Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{},
		Now: func() time.Time { return time.Unix(1700006000, 0) },
	}
	result, err := manager.Uninstall(context.Background(), UninstallOptions{DeleteData: true})
	if err == nil || !strings.Contains(err.Error(), "remove stopped services") || result.Backup == "" {
		t.Fatalf("result=%+v err=%v", result, err)
	}
	if _, err := loadManifest(installer.Paths.ManifestPath); err != nil {
		t.Fatalf("manifest was removed: %v", err)
	}
	if raw, err := os.ReadFile(database); err != nil || string(raw) != "persistent-state" {
		t.Fatalf("database changed=%q err=%v", raw, err)
	}
}

func TestApplyBackupRestoresMissingDataRoot(t *testing.T) {
	installer, runner, _ := createUninstallFixture(t)
	backup, err := (BackupManager{
		Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{},
		Now: func() time.Time { return time.Unix(1700007000, 0) },
	}).Create(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	current, err := loadManifest(installer.Paths.ManifestPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(installer.Paths.DataDir); err != nil {
		t.Fatal(err)
	}
	if _, err := applyBackup(backup, current, installer.Paths); err != nil {
		t.Fatal(err)
	}
	if _, err := loadManifest(installer.Paths.ManifestPath); err != nil {
		t.Fatalf("data root was not restored: %v", err)
	}
}

func TestRestoreRecoversKeepDataUninstall(t *testing.T) {
	installer, runner, database := createUninstallFixture(t)
	uninstall, err := (UninstallManager{
		Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{},
		Now: func() time.Time { return time.Unix(1700008000, 0) },
	}).Uninstall(context.Background(), UninstallOptions{KeepData: true})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(database, []byte("retained-after-uninstall"), 0o600); err != nil {
		t.Fatal(err)
	}
	rollback, err := (RestoreManager{Paths: installer.Paths, Runner: runner, Verifier: &sequenceVerifier{}, Chown: installer.Chown}).Restore(context.Background(), uninstall.Backup)
	if err != nil || rollback != "" {
		t.Fatalf("rollback=%q err=%v", rollback, err)
	}
	if raw, err := os.ReadFile(database); err != nil || string(raw) != "persistent-state" {
		t.Fatalf("recovered database=%q err=%v", raw, err)
	}
	if _, err := loadManifest(installer.Paths.ManifestPath); err != nil {
		t.Fatalf("ownership was not recovered: %v", err)
	}
}

func TestFailedRecoveryRestoreReturnsToRetainedUninstalledState(t *testing.T) {
	installer, runner, database := createUninstallFixture(t)
	uninstall, err := (UninstallManager{
		Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{},
		Now: func() time.Time { return time.Unix(1700009000, 0) },
	}).Uninstall(context.Background(), UninstallOptions{KeepData: true})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(database, []byte("retained-after-uninstall"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err = (RestoreManager{Paths: installer.Paths, Runner: runner, Verifier: &sequenceVerifier{failAt: 1}, Chown: installer.Chown}).Restore(context.Background(), uninstall.Backup)
	if err == nil || !strings.Contains(err.Error(), "uninstalled state was restored") {
		t.Fatalf("recovery result: %v", err)
	}
	if raw, err := os.ReadFile(database); err != nil || string(raw) != "retained-after-uninstall" {
		t.Fatalf("retained database=%q err=%v", raw, err)
	}
	for _, absent := range []string{installer.Paths.ManifestPath, installer.Paths.Compose, installer.Paths.RelayEnv} {
		if _, err := os.Lstat(absent); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("restored file remained after rollback %s: %v", absent, err)
		}
	}
}
