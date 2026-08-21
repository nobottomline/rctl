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

type sequenceVerifier struct {
	calls  int
	failAt int
	before func(int) error
}

func (v *sequenceVerifier) Verify(context.Context, Config, string) error {
	v.calls++
	if v.before != nil {
		if err := v.before(v.calls); err != nil {
			return err
		}
	}
	if v.calls == v.failAt {
		return errors.New("synthetic public verification failure")
	}
	return nil
}

func (v *sequenceVerifier) VerifyPersistence(ctx context.Context, _ Config, _ string, restart func(context.Context) error) error {
	return restart(ctx)
}

func createRestoreFixture(t *testing.T) (Installer, *fakeRunner, string, string) {
	t.Helper()
	runner := &fakeRunner{}
	installer := testInstaller(t, runner, &fakeVerifier{})
	if _, err := installer.Install(context.Background(), validConfig(), InstallOptions{Version: "1.2.3"}); err != nil {
		t.Fatal(err)
	}
	database := filepath.Join(installer.Paths.RelayDataDir, "rctl-relay.db")
	if err := os.WriteFile(database, []byte("state-a"), 0o600); err != nil {
		t.Fatal(err)
	}
	source, err := (BackupManager{
		Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{},
		Now: func() time.Time { return time.Unix(1700001000, 0) },
	}).Create(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(database, []byte("state-b"), 0o600); err != nil {
		t.Fatal(err)
	}
	return installer, runner, source, database
}

func TestRestoreReplacesStateAndKeepsPreRestoreBackup(t *testing.T) {
	installer, runner, source, database := createRestoreFixture(t)
	manager := RestoreManager{Paths: installer.Paths, Runner: runner, Verifier: &sequenceVerifier{}, Chown: installer.Chown}
	metadata, err := manager.DryRun(source)
	if err != nil || metadata.Release != "1.2.3" {
		t.Fatalf("dry run metadata=%+v err=%v", metadata, err)
	}
	beforeCalls := len(runner.calls)
	if _, err := manager.DryRun(source); err != nil || len(runner.calls) != beforeCalls {
		t.Fatalf("dry run mutated services: err=%v calls=%v", err, runner.calls[beforeCalls:])
	}
	rollback, err := manager.Restore(context.Background(), source)
	if err != nil {
		t.Fatal(err)
	}
	if calls := strings.Join(runner.calls, "\n"); !strings.Contains(calls, "docker compose --project-name rctl --file "+installer.Paths.Compose+" stop") {
		t.Fatalf("restore did not stop the complete stack:\n%s", calls)
	}
	if _, err := ValidateBackup(rollback); err != nil {
		t.Fatalf("pre-restore backup is invalid: %v", err)
	}
	raw, err := os.ReadFile(database)
	if err != nil || string(raw) != "state-a" {
		t.Fatalf("restored database=%q err=%v", raw, err)
	}
	rollbackDB := snapshotPath(rollback, database)
	raw, err = os.ReadFile(rollbackDB)
	if err != nil || string(raw) != "state-b" {
		t.Fatalf("pre-restore database=%q err=%v", raw, err)
	}
}

func TestRestoreRejectsUnmanagedAndTamperedBackupBeforeServiceMutation(t *testing.T) {
	installer, runner, source, database := createRestoreFixture(t)
	manager := RestoreManager{Paths: installer.Paths, Runner: runner, Verifier: &sequenceVerifier{}, Chown: installer.Chown}
	beforeCalls := len(runner.calls)
	if _, err := manager.Restore(context.Background(), t.TempDir()); err == nil || !strings.Contains(err.Error(), "direct backup-*") {
		t.Fatalf("unmanaged backup result: %v", err)
	}
	if len(runner.calls) != beforeCalls {
		t.Fatal("unmanaged backup changed service state")
	}
	if err := os.WriteFile(snapshotPath(source, database), []byte("tampered"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Restore(context.Background(), source); err == nil || !strings.Contains(err.Error(), "digest differs") {
		t.Fatalf("tampered backup result: %v", err)
	}
	if len(runner.calls) != beforeCalls {
		t.Fatal("tampered backup changed service state")
	}
}

func TestRestoreRollsBackWhenRestoredRuntimeFailsVerification(t *testing.T) {
	installer, runner, source, database := createRestoreFixture(t)
	verifier := &sequenceVerifier{failAt: 2}
	rollback, err := (RestoreManager{Paths: installer.Paths, Runner: runner, Verifier: verifier, Chown: installer.Chown}).Restore(context.Background(), source)
	if err == nil || !strings.Contains(err.Error(), "was rolled back") {
		t.Fatalf("restore result: rollback=%s err=%v", rollback, err)
	}
	if verifier.calls != 3 {
		t.Fatalf("verification calls=%d, expected backup, restore, rollback", verifier.calls)
	}
	raw, readErr := os.ReadFile(database)
	if readErr != nil || string(raw) != "state-b" {
		t.Fatalf("rollback database=%q err=%v", raw, readErr)
	}
	if _, validateErr := ValidateBackup(rollback); validateErr != nil {
		t.Fatalf("rollback backup is invalid: %v", validateErr)
	}
}

func TestRestoreRollbackRemovesFilesOwnedOnlyByFailedTarget(t *testing.T) {
	runner := &fakeRunner{}
	installer := testInstaller(t, runner, &fakeVerifier{})
	withoutTURN := validConfig()
	withoutTURN.EnableTURN = false
	withoutTURN.CoturnImage = ""
	withoutTURN.TURNExternalIP = ""
	if _, err := installer.Install(context.Background(), withoutTURN, InstallOptions{Version: "1.2.3"}); err != nil {
		t.Fatal(err)
	}
	rollbackSource, err := (BackupManager{
		Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{},
		Now: func() time.Time { return time.Unix(1700001100, 0) },
	}).Create(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	secrets, err := readExistingSecrets(installer.Paths.RelayEnv)
	if err != nil {
		t.Fatal(err)
	}
	secrets.TURN = strings.Repeat("a", 64)
	withTURN := validConfig()
	targetBundle, err := RenderDedicatedBundleAt(withTURN, secrets, installer.Paths)
	if err != nil {
		t.Fatal(err)
	}
	for _, file := range targetBundle.Files {
		if err := writeFileAtomic(file.Path, file.Content, os.FileMode(file.Mode)); err != nil {
			t.Fatal(err)
		}
	}
	targetManifest := manifestFor(withTURN, targetBundle, "1.2.3", time.Unix(1700000000, 0).Unix(), time.Unix(1700001200, 0).Unix())
	if err := writeJSONAtomic(installer.Paths.ManifestPath, targetManifest, 0o600); err != nil {
		t.Fatal(err)
	}
	targetSource, err := (BackupManager{
		Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{},
		Now: func() time.Time { return time.Unix(1700001200, 0) },
	}).Create(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := applyBackup(rollbackSource, targetManifest, installer.Paths); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(installer.Paths.Coturn); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("TURN file remained before restore test: %v", err)
	}

	verifier := &sequenceVerifier{failAt: 2}
	if _, err := (RestoreManager{Paths: installer.Paths, Runner: runner, Verifier: verifier, Chown: installer.Chown}).Restore(context.Background(), targetSource); err == nil || !strings.Contains(err.Error(), "was rolled back") {
		t.Fatalf("restore result: %v", err)
	}
	if _, err := os.Lstat(installer.Paths.Coturn); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("failed target TURN file survived rollback: %v", err)
	}
	manifest, err := loadManifest(installer.Paths.ManifestPath)
	if err != nil || manifest.Config.EnableTURN {
		t.Fatalf("rollback manifest=%+v err=%v", manifest, err)
	}
}

func TestBackupValidationRejectsAggregateSizeOverflow(t *testing.T) {
	name := filepath.Join(t.TempDir(), "backup-oversized")
	if err := os.Mkdir(name, 0o700); err != nil {
		t.Fatal(err)
	}
	digest := strings.Repeat("0", 64)
	metadata := BackupMetadata{
		Schema: backupSchema, Product: "rctl", CreatedAt: 1700000000, Release: "1.2.3", Config: validConfig(),
		Entries: []BackupEntry{
			{Path: "var/lib/rctl/a", Type: "file", Mode: 0o600, Size: maxBackupBytes, SHA256: digest},
			{Path: "var/lib/rctl/b", Type: "file", Mode: 0o600, Size: 1, SHA256: digest},
		},
	}
	if err := writeJSONAtomic(filepath.Join(name, "backup.json"), metadata, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ValidateBackup(name); err == nil || !strings.Contains(err.Error(), "aggregate size limit") {
		t.Fatalf("oversized metadata result: %v", err)
	}
}
