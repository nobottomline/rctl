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

type callbackVerifier struct {
	verify func() error
}

func (v callbackVerifier) Verify(context.Context, Config, string) error {
	if v.verify != nil {
		return v.verify()
	}
	return nil
}

func (v callbackVerifier) VerifyPersistence(ctx context.Context, _ Config, _ string, restart func(context.Context) error) error {
	return restart(ctx)
}

func TestMutationBackupCapturesLatestStoppedStateAndKeepsLock(t *testing.T) {
	installer, runner, database, _ := createUpgradeFixture(t)
	expected, err := loadManifest(installer.Paths.ManifestPath)
	if err != nil {
		t.Fatal(err)
	}
	verifier := callbackVerifier{verify: func() error {
		return os.WriteFile(database, []byte("latest-state-before-stop"), 0o600)
	}}
	mutation, err := (BackupManager{
		Paths: installer.Paths, Runner: runner, Verifier: verifier,
		Now: func() time.Time { return time.Unix(1700004200, 0) },
	}).BeginMutation(context.Background(), "upgrade", expected)
	if err != nil {
		t.Fatal(err)
	}
	defer mutation.Release()

	backupDatabase := snapshotPath(mutation.Backup, database)
	if raw, err := os.ReadFile(backupDatabase); err != nil || string(raw) != "latest-state-before-stop" {
		t.Fatalf("mutation backup state=%q err=%v", raw, err)
	}
	state, err := pendingRecovery(installer.Paths)
	if err != nil || state.Operation != "upgrade" || state.Backup != mutation.Backup {
		t.Fatalf("recovery state=%+v err=%v", state, err)
	}
	if release, err := acquireLifecycleLock(installer.Paths.LockPath); err == nil {
		release()
		t.Fatal("mutation released the lifecycle lock before completion")
	}
	if calls := strings.Join(runner.calls, "\n"); !strings.Contains(calls, " stop") {
		t.Fatalf("services were not stopped before the snapshot:\n%s", calls)
	}
	if err := clearRecovery(installer.Paths); err != nil {
		t.Fatal(err)
	}
	mutation.Release()
	if release, err := acquireLifecycleLock(installer.Paths.LockPath); err != nil {
		t.Fatalf("lifecycle lock remained after release: %v", err)
	} else {
		release()
	}
}

func TestBackupStopFailureRestartsAndClearsRecovery(t *testing.T) {
	installer, runner, _, _ := createUpgradeFixture(t)
	runner.failContains = " stop relay caddy"
	_, err := (BackupManager{
		Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{},
		Now: func() time.Time { return time.Unix(1700004300, 0) },
	}).Create(context.Background())
	if err == nil || !strings.Contains(err.Error(), "stop services for consistent backup") {
		t.Fatalf("backup result: %v", err)
	}
	if _, err := os.Lstat(installer.Paths.RecoveryPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("backup recovery checkpoint remained: %v", err)
	}
	if entries, err := os.ReadDir(installer.Paths.BackupDir); err != nil || len(entries) != 0 {
		t.Fatalf("failed backup artifacts=%v err=%v", entries, err)
	}
	if calls := strings.Join(runner.calls, "\n"); !strings.Contains(calls, " up -d relay caddy") {
		t.Fatalf("backup failure did not restart services:\n%s", calls)
	}
}

func TestMutationBackupRejectsChangedOwnershipBeforeStopping(t *testing.T) {
	installer, runner, _, _ := createUpgradeFixture(t)
	expected, err := loadManifest(installer.Paths.ManifestPath)
	if err != nil {
		t.Fatal(err)
	}
	expected.Version = "different"
	before := len(runner.calls)
	mutation, err := (BackupManager{Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{}}).BeginMutation(context.Background(), "upgrade", expected)
	mutation.Release()
	if err == nil || !strings.Contains(err.Error(), "state changed before the mutation backup") {
		t.Fatalf("mutation result: %v", err)
	}
	if calls := strings.Join(runner.calls[before:], "\n"); strings.Contains(calls, " stop") {
		t.Fatalf("changed deployment was stopped:\n%s", calls)
	}
	if _, err := os.Lstat(filepath.Clean(installer.Paths.RecoveryPath)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("recovery checkpoint created for rejected mutation: %v", err)
	}
}

func TestMutationBackupRejectsManagedFileDriftDuringStopAndRestarts(t *testing.T) {
	installer, runner, _, _ := createUpgradeFixture(t)
	expected, err := loadManifest(installer.Paths.ManifestPath)
	if err != nil {
		t.Fatal(err)
	}
	verifier := callbackVerifier{verify: func() error {
		return os.WriteFile(installer.Paths.Caddyfile, []byte("externally changed"), 0o644)
	}}
	mutation, err := (BackupManager{
		Paths: installer.Paths, Runner: runner, Verifier: verifier,
		Now: func() time.Time { return time.Unix(1700004400, 0) },
	}).BeginMutation(context.Background(), "upgrade", expected)
	mutation.Release()
	if err == nil || !strings.Contains(err.Error(), "revalidate stopped deployment") {
		t.Fatalf("mutation result: %v", err)
	}
	if mutation.Backup != "" {
		t.Fatalf("drifted state produced backup %s", mutation.Backup)
	}
	if _, err := os.Lstat(installer.Paths.RecoveryPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("recovery checkpoint remained: %v", err)
	}
	if calls := strings.Join(runner.calls, "\n"); !strings.Contains(calls, " up -d") {
		t.Fatalf("drift rejection did not restart services:\n%s", calls)
	}
}
