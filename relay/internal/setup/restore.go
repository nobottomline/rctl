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
	"time"
)

type RestoreManager struct {
	Paths    Paths
	Runner   Runner
	Verifier PublicVerifier
}

func (r RestoreManager) DryRun(source string) (BackupMetadata, error) {
	r.defaults()
	if err := ensureNoPendingRecovery(r.Paths); err != nil {
		return BackupMetadata{}, err
	}
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
	if errors.Is(err, os.ErrNotExist) {
		if err := validateUninstalledRestoreTarget(manifest, r.Paths); err != nil {
			return BackupMetadata{}, err
		}
		return metadata, nil
	}
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
	if _, manifestErr := loadManifest(r.Paths.ManifestPath); errors.Is(manifestErr, os.ErrNotExist) {
		return "", r.restoreUninstalled(ctx, source)
	} else if manifestErr != nil {
		return "", manifestErr
	}
	expected, err := loadManifest(r.Paths.ManifestPath)
	if err != nil {
		return "", err
	}
	restoreTarget, err := snapshotOwnership(source, r.Paths)
	if err != nil {
		return "", fmt.Errorf("read restore source ownership: %w", err)
	}
	mutation, err := (BackupManager{Paths: r.Paths, Runner: r.Runner, Verifier: r.Verifier}).BeginMutation(ctx, "restore", expected)
	rollbackBackup = mutation.Backup
	if err != nil {
		return rollbackBackup, fmt.Errorf("create pre-restore mutation backup: %w", err)
	}
	defer mutation.Release()
	current := mutation.Manifest
	rollbackManifest := mutation.Manifest
	installer := Installer{Paths: r.Paths, Runner: r.Runner, Verifier: r.Verifier}
	restored, applyErr := applyBackup(source, current, r.Paths)
	if applyErr == nil {
		applyErr = r.startAndVerify(ctx, installer, restored)
	}
	if applyErr == nil {
		if clearErr := clearRecovery(r.Paths); clearErr != nil {
			return rollbackBackup, fmt.Errorf("restore verified but recovery checkpoint could not be committed: %w", clearErr)
		}
		return rollbackBackup, nil
	}

	_, rollbackErr := applyBackup(rollbackBackup, restoreTarget, r.Paths)
	if rollbackErr == nil {
		rollbackCtx, cancel := lifecycleRecoveryContext()
		defer cancel()
		rollbackErr = r.startAndVerify(rollbackCtx, installer, rollbackManifest)
	}
	if rollbackErr != nil {
		return rollbackBackup, fmt.Errorf("restore failed: %v; automatic rollback also failed: %w", applyErr, rollbackErr)
	}
	if clearErr := clearRecovery(r.Paths); clearErr != nil {
		return rollbackBackup, fmt.Errorf("restore failed and was rolled back, but recovery checkpoint remains: %v: %w", applyErr, clearErr)
	}
	return rollbackBackup, fmt.Errorf("restore failed and was rolled back: %w", applyErr)
}

func (r RestoreManager) restoreUninstalled(ctx context.Context, source string) (err error) {
	releaseLock, err := acquireLifecycleLock(r.Paths.LockPath)
	if err != nil {
		return err
	}
	defer releaseLock()
	if _, err := r.DryRun(source); err != nil {
		return fmt.Errorf("revalidate recovery restore source: %w", err)
	}
	target, err := snapshotOwnership(source, r.Paths)
	if err != nil {
		return err
	}
	retainedData := ""
	installer := Installer{Paths: r.Paths, Runner: r.Runner, Verifier: r.Verifier}
	applied := false
	mutationStarted := false
	verified := false
	if err := beginRecovery(r.Paths, "restore-uninstalled", source, time.Now()); err != nil {
		return err
	}
	defer func() {
		if verified {
			if retainedData != "" {
				if cleanupErr := os.RemoveAll(retainedData); cleanupErr != nil {
					err = fmt.Errorf("restore verified but retained data cleanup failed at %s: %w", retainedData, cleanupErr)
				}
			}
			if clearErr := clearRecovery(r.Paths); clearErr != nil {
				err = errors.Join(err, fmt.Errorf("commit recovery restore checkpoint: %w", clearErr))
			}
			return
		}
		if !mutationStarted {
			_ = clearRecovery(r.Paths)
			return
		}
		recoveryCtx, cancel := lifecycleRecoveryContext()
		defer cancel()
		if applied {
			_, _ = r.Runner.Run(recoveryCtx, "docker", installer.composeArgs("down", "--remove-orphans")...)
		}
		rollbackErr := removeRestoredState(target, r.Paths)
		if rollbackErr == nil && retainedData != "" {
			rollbackErr = os.Rename(retainedData, r.Paths.DataDir)
		}
		if rollbackErr != nil {
			err = fmt.Errorf("recovery restore failed: %v; restoring the uninstalled state also failed: %w", err, rollbackErr)
			return
		}
		if clearErr := clearRecovery(r.Paths); clearErr != nil {
			err = fmt.Errorf("recovery restore failed and the uninstalled state was restored, but checkpoint remains: %v: %w", err, clearErr)
			return
		}
		err = fmt.Errorf("recovery restore failed and the uninstalled state was restored: %w", err)
	}()
	if _, statErr := os.Lstat(r.Paths.DataDir); statErr == nil {
		retainedData, err = reserveRetainedData(r.Paths.DataDir)
		if err != nil {
			return err
		}
		mutationStarted = true
	} else if !errors.Is(statErr, os.ErrNotExist) {
		return statErr
	}
	mutationStarted = true
	if _, err = applyBackup(source, target, r.Paths); err != nil {
		applied = true
		return err
	}
	applied = true
	if err = r.startAndVerify(ctx, installer, target); err != nil {
		return err
	}
	verified = true
	return nil
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
	if err := r.Verifier.Verify(ctx, manifest.Config, secrets.Admin); err != nil {
		return err
	}
	restart := func(restartCtx context.Context) error {
		if output, err := r.Runner.Run(restartCtx, "docker", installer.composeArgs("restart", "relay")...); err != nil {
			return fmt.Errorf("recovery persistence restart: %s", commandFailure(output, err))
		}
		return installer.waitForServices(restartCtx, manifest.Config.EnableTURN)
	}
	if err := r.Verifier.VerifyPersistence(ctx, manifest.Config, secrets.Admin, restart); err != nil {
		return fmt.Errorf("recovery persistence verification: %w", err)
	}
	return nil
}

func validateBackupSelection(source, backupRoot string) error {
	clean := filepath.Clean(source)
	if filepath.Dir(clean) != filepath.Clean(backupRoot) || !strings.HasPrefix(filepath.Base(clean), "backup-") {
		return errors.New("restore source must be a direct backup-* child of the managed backup directory")
	}
	return nil
}

func validateUninstalledRestoreTarget(target OwnershipManifest, paths Paths) error {
	for _, file := range target.Files {
		if pathWithin(file.Path, paths.DataDir) {
			continue
		}
		if _, err := os.Lstat(file.Path); err == nil {
			return fmt.Errorf("unowned restore destination already exists: %s", file.Path)
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if info, err := os.Lstat(paths.DataDir); err == nil {
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("retained data path is not a safe directory")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func reserveRetainedData(dataDir string) (string, error) {
	temporary, err := os.MkdirTemp(filepath.Dir(dataDir), ".rctl-retained-")
	if err != nil {
		return "", err
	}
	if err := os.Remove(temporary); err != nil {
		return "", err
	}
	if err := os.Rename(dataDir, temporary); err != nil {
		return "", err
	}
	return temporary, nil
}

func removeRestoredState(target OwnershipManifest, paths Paths) error {
	var result error
	for _, file := range target.Files {
		if pathWithin(file.Path, paths.DataDir) {
			continue
		}
		if err := os.Remove(file.Path); err != nil && !errors.Is(err, os.ErrNotExist) {
			result = errors.Join(result, err)
		}
	}
	if err := os.RemoveAll(paths.DataDir); err != nil {
		result = errors.Join(result, err)
	}
	return result
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
	hadOldData := false
	if info, err := os.Lstat(paths.DataDir); err == nil {
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return OwnershipManifest{}, errors.New("existing data path is not a safe directory")
		}
		if err := os.Rename(paths.DataDir, oldData); err != nil {
			return OwnershipManifest{}, err
		}
		hadOldData = true
	} else if !errors.Is(err, os.ErrNotExist) {
		return OwnershipManifest{}, err
	}
	if err := os.Rename(staging, paths.DataDir); err != nil {
		if hadOldData {
			_ = os.Rename(oldData, paths.DataDir)
		}
		return OwnershipManifest{}, err
	}
	if hadOldData {
		_ = os.RemoveAll(oldData)
	}
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
