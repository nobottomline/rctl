package setup

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

type RestoreManager struct {
	Paths    Paths
	Runner   Runner
	Verifier PublicVerifier
}

func (r RestoreManager) DryRun(source string) (BackupMetadata, error) {
	r.defaults()
	if err := validateBackupSelection(source, r.Paths.BackupDir); err != nil {
		return BackupMetadata{}, err
	}
	metadata, err := ValidateBackup(source)
	if err != nil {
		return BackupMetadata{}, err
	}
	manifest, err := snapshotOwnership(source, r.Paths)
	if err != nil {
		return BackupMetadata{}, err
	}
	if manifest.Version != metadata.Release || !configsEqual(manifest.Config, metadata.Config) {
		return BackupMetadata{}, errors.New("backup metadata and ownership manifest disagree")
	}
	current, err := loadManifest(r.Paths.ManifestPath)
	if err != nil {
		return BackupMetadata{}, err
	}
	if err := validateOwnershipManifest(current, r.Paths); err != nil {
		return BackupMetadata{}, err
	}
	if err := verifyOwnedFiles(current); err != nil {
		return BackupMetadata{}, err
	}
	return metadata, nil
}

func (r RestoreManager) Restore(ctx context.Context, source string) (rollbackBackup string, err error) {
	r.defaults()
	if _, err := r.DryRun(source); err != nil {
		return "", err
	}
	rollbackBackup, err = (BackupManager{Paths: r.Paths, Runner: r.Runner, Verifier: r.Verifier}).Create(ctx)
	if err != nil {
		return "", fmt.Errorf("create pre-restore backup: %w", err)
	}
	releaseLock, err := acquireLifecycleLock(r.Paths.LockPath)
	if err != nil {
		return rollbackBackup, err
	}
	defer releaseLock()
	if _, err := r.DryRun(source); err != nil {
		return rollbackBackup, fmt.Errorf("revalidate restore source: %w", err)
	}
	rollbackManifest, err := snapshotOwnership(rollbackBackup, r.Paths)
	if err != nil {
		return rollbackBackup, fmt.Errorf("read pre-restore backup: %w", err)
	}
	current, err := loadManifest(r.Paths.ManifestPath)
	if err != nil {
		return rollbackBackup, err
	}
	if err := validateOwnershipManifest(current, r.Paths); err != nil {
		return rollbackBackup, err
	}
	if err := verifyOwnedFiles(current); err != nil {
		return rollbackBackup, err
	}
	if !ownershipManifestsEqual(current, rollbackManifest) {
		return rollbackBackup, errors.New("installed state changed after the pre-restore backup; refusing to overwrite it")
	}
	installer := Installer{Paths: r.Paths, Runner: r.Runner, Verifier: r.Verifier}
	if output, stopErr := r.Runner.Run(ctx, "docker", installer.composeArgs("stop", "relay", "caddy")...); stopErr != nil {
		return rollbackBackup, fmt.Errorf("stop services for restore: %s", commandFailure(output, stopErr))
	}
	restored, applyErr := applyBackup(source, current, r.Paths)
	if applyErr == nil {
		applyErr = r.startAndVerify(ctx, installer, restored)
	}
	if applyErr == nil {
		return rollbackBackup, nil
	}

	rollbackCurrent := current
	if applyErr == nil {
		rollbackCurrent = restored
	}
	_, rollbackErr := applyBackup(rollbackBackup, rollbackCurrent, r.Paths)
	if rollbackErr == nil {
		rollbackErr = r.startAndVerify(ctx, installer, rollbackManifest)
	}
	if rollbackErr != nil {
		return rollbackBackup, fmt.Errorf("restore failed: %v; automatic rollback also failed: %w", applyErr, rollbackErr)
	}
	return rollbackBackup, fmt.Errorf("restore failed and was rolled back: %w", applyErr)
}

func (r *RestoreManager) defaults() {
	if r.Paths.EtcDir == "" {
		r.Paths = DefaultPaths()
	}
	if r.Runner == nil {
		r.Runner = OSRunner{}
	}
	if r.Verifier == nil {
		r.Verifier = HTTPSVerifier{}
	}
}

func (r RestoreManager) startAndVerify(ctx context.Context, installer Installer, manifest OwnershipManifest) error {
	if output, err := r.Runner.Run(ctx, "docker", installer.composeArgs("up", "-d", "--remove-orphans")...); err != nil {
		return fmt.Errorf("start restored services: %s", commandFailure(output, err))
	}
	if err := installer.waitForServices(ctx, manifest.Config.EnableTURN); err != nil {
		return err
	}
	secrets, err := readExistingSecrets(r.Paths.RelayEnv)
	if err != nil {
		return err
	}
	return r.Verifier.Verify(ctx, manifest.Config, secrets.Admin)
}

func validateBackupSelection(source, backupRoot string) error {
	clean := filepath.Clean(source)
	if filepath.Dir(clean) != filepath.Clean(backupRoot) || !strings.HasPrefix(filepath.Base(clean), "backup-") {
		return errors.New("restore source must be a direct backup-* child of the managed backup directory")
	}
	return nil
}

func snapshotOwnership(snapshot string, paths Paths) (OwnershipManifest, error) {
	name := snapshotPath(snapshot, paths.ManifestPath)
	manifest, err := loadManifest(name)
	if err != nil {
		return OwnershipManifest{}, err
	}
	if err := validateOwnershipManifest(manifest, paths); err != nil {
		return OwnershipManifest{}, err
	}
	return manifest, nil
}

func snapshotPath(snapshot, absolute string) string {
	return filepath.Join(snapshot, "root", strings.TrimPrefix(filepath.Clean(absolute), string(filepath.Separator)))
}

func ownershipManifestsEqual(a, b OwnershipManifest) bool {
	aRaw, _ := json.Marshal(a)
	bRaw, _ := json.Marshal(b)
	return string(aRaw) == string(bRaw)
}

func applyBackup(snapshot string, current OwnershipManifest, paths Paths) (OwnershipManifest, error) {
	if _, err := ValidateBackup(snapshot); err != nil {
		return OwnershipManifest{}, err
	}
	target, err := snapshotOwnership(snapshot, paths)
	if err != nil {
		return OwnershipManifest{}, err
	}
	staging, err := os.MkdirTemp(filepath.Dir(paths.DataDir), ".rctl-restore-")
	if err != nil {
		return OwnershipManifest{}, err
	}
	_ = os.Remove(staging)
	defer os.RemoveAll(staging)
	if err := restoreTree(snapshotPath(snapshot, paths.DataDir), staging); err != nil {
		return OwnershipManifest{}, err
	}
	for _, file := range target.Files {
		if pathWithin(file.Path, paths.DataDir) {
			continue
		}
		if err := restoreRegularFile(snapshotPath(snapshot, file.Path), file.Path, os.FileMode(file.Mode)); err != nil {
			return OwnershipManifest{}, err
		}
	}
	oldData := paths.DataDir + ".restore-old"
	_ = os.RemoveAll(oldData)
	if err := os.Rename(paths.DataDir, oldData); err != nil {
		return OwnershipManifest{}, err
	}
	if err := os.Rename(staging, paths.DataDir); err != nil {
		_ = os.Rename(oldData, paths.DataDir)
		return OwnershipManifest{}, err
	}
	_ = os.RemoveAll(oldData)
	targetPaths := make(map[string]bool)
	for _, file := range target.Files {
		targetPaths[file.Path] = true
	}
	for _, file := range current.Files {
		if !targetPaths[file.Path] && !pathWithin(file.Path, paths.DataDir) {
			_ = os.Remove(file.Path)
		}
	}
	if err := verifyOwnedFiles(target); err != nil {
		return target, err
	}
	return target, nil
}

func restoreTree(source, destination string) error {
	return filepath.Walk(source, func(name string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative, err := filepath.Rel(source, name)
		if err != nil {
			return err
		}
		target := destination
		if relative != "." {
			target = filepath.Join(destination, relative)
		}
		uid, gid, err := fileOwnership(info)
		if err != nil {
			return err
		}
		if info.IsDir() {
			if err := os.MkdirAll(target, info.Mode().Perm()); err != nil {
				return err
			}
			if err := os.Chmod(target, info.Mode().Perm()); err != nil {
				return err
			}
			return os.Chown(target, int(uid), int(gid))
		}
		return restoreRegularFile(name, target, info.Mode().Perm())
	})
}

func restoreRegularFile(source, destination string, mode os.FileMode) error {
	info, err := os.Lstat(source)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != mode.Perm() || info.Size() < 0 || info.Size() > maxBackupBytes {
		return fmt.Errorf("restore source %s is not a valid regular file", source)
	}
	uid, gid, err := fileOwnership(info)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
		return err
	}
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	temporary, err := os.CreateTemp(filepath.Dir(destination), ".rctl-restore-*")
	if err != nil {
		return err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(mode); err != nil {
		temporary.Close()
		return err
	}
	written, copyErr := io.Copy(temporary, io.LimitReader(in, info.Size()+1))
	if copyErr == nil && written != info.Size() {
		copyErr = errors.New("restore source changed while it was copied")
	}
	if copyErr == nil {
		copyErr = temporary.Sync()
	}
	if copyErr == nil {
		copyErr = temporary.Chown(int(uid), int(gid))
	}
	closeErr := temporary.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	if err := os.Rename(temporaryName, destination); err != nil {
		return err
	}
	return syncDirectory(filepath.Dir(destination))
}
