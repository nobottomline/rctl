package setup

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sort"
	"syscall"
	"time"
)

type UninstallOptions struct {
	DryRun     bool
	KeepData   bool
	DeleteData bool
}

type UninstallResult struct {
	DryRun    bool
	KeepData  bool
	Backup    string
	Removed   []string
	Preserved []string
}

type UninstallManager struct {
	Paths    Paths
	Runner   Runner
	Verifier PublicVerifier
	Now      func() time.Time
}

func (u UninstallManager) Plan(options UninstallOptions) (UninstallResult, error) {
	u.defaults()
	if err := ensureNoPendingRecovery(u.Paths); err != nil {
		return UninstallResult{}, err
	}
	if options.KeepData == options.DeleteData {
		return UninstallResult{}, errors.New("choose exactly one of keep-data or delete-data")
	}
	manifest, err := loadManifest(u.Paths.ManifestPath)
	if err != nil {
		return UninstallResult{}, err
	}
	if err := validateOwnershipManifest(manifest, u.Paths); err != nil {
		return UninstallResult{}, err
	}
	if err := verifyOwnedFiles(manifest); err != nil {
		return UninstallResult{}, err
	}
	if _, err := (BackupManager{Paths: u.Paths}).DryRun(); err != nil {
		return UninstallResult{}, err
	}
	removed := make([]string, 0, len(manifest.Files)+1)
	for _, file := range manifest.Files {
		if !pathWithin(file.Path, u.Paths.DataDir) {
			removed = append(removed, file.Path)
		}
	}
	if options.DeleteData {
		removed = append(removed, u.Paths.DataDir)
	} else {
		removed = append(removed, u.Paths.ManifestPath)
	}
	sort.Strings(removed)
	preserved := []string{u.Paths.BackupDir, u.Paths.LogDir}
	if options.KeepData {
		preserved = append(preserved, u.Paths.DataDir)
	}
	return UninstallResult{DryRun: options.DryRun, KeepData: options.KeepData, Removed: removed, Preserved: preserved}, nil
}

func (u UninstallManager) Uninstall(ctx context.Context, options UninstallOptions) (result UninstallResult, err error) {
	u.defaults()
	result, err = u.Plan(options)
	if err != nil || options.DryRun {
		return result, err
	}
	result.Backup, err = (BackupManager{Paths: u.Paths, Runner: u.Runner, Verifier: u.Verifier, Now: u.Now}).Create(ctx)
	if err != nil {
		return result, fmt.Errorf("create pre-uninstall backup: %w", err)
	}
	releaseLock, err := acquireLifecycleLock(u.Paths.LockPath)
	if err != nil {
		return result, err
	}
	defer releaseLock()
	current, err := loadManifest(u.Paths.ManifestPath)
	if err != nil {
		return result, err
	}
	backupManifest, err := snapshotOwnership(result.Backup, u.Paths)
	if err != nil {
		return result, err
	}
	if !ownershipManifestsEqual(current, backupManifest) {
		return result, errors.New("installed state changed after the pre-uninstall backup; refusing to remove it")
	}
	if err := verifyOwnedFiles(current); err != nil {
		return result, err
	}
	installer := Installer{Paths: u.Paths, Runner: u.Runner, Verifier: u.Verifier}
	if err := beginRecovery(u.Paths, "uninstall", result.Backup, u.Now()); err != nil {
		return result, err
	}
	if output, downErr := u.Runner.Run(ctx, "docker", installer.composeArgs("down", "--remove-orphans")...); downErr != nil {
		_, _ = u.Runner.Run(context.Background(), "docker", installer.composeArgs("up", "-d")...)
		return result, fmt.Errorf("stop and remove services: %s", commandFailure(output, downErr))
	}

	mutationStarted := false
	defer func() {
		if err == nil || !mutationStarted {
			return
		}
		_, rollbackErr := applyBackup(result.Backup, current, u.Paths)
		if rollbackErr == nil {
			rollbackErr = (RestoreManager{Paths: u.Paths, Runner: u.Runner, Verifier: u.Verifier}).startAndVerify(context.Background(), installer, backupManifest)
		}
		if rollbackErr != nil {
			err = fmt.Errorf("uninstall failed: %v; automatic rollback also failed: %w", err, rollbackErr)
			return
		}
		if clearErr := clearRecovery(u.Paths); clearErr != nil {
			err = fmt.Errorf("uninstall failed and was rolled back, but recovery checkpoint remains: %v: %w", err, clearErr)
			return
		}
		err = fmt.Errorf("uninstall failed and was rolled back: %w", err)
	}()

	mutationStarted = true
	for _, file := range current.Files {
		if pathWithin(file.Path, u.Paths.DataDir) {
			continue
		}
		if removeErr := os.Remove(file.Path); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
			return result, removeErr
		}
	}
	if options.DeleteData {
		if err = os.RemoveAll(u.Paths.DataDir); err != nil {
			return result, err
		}
	} else if err = os.Remove(u.Paths.ManifestPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return result, err
	}
	for _, directory := range []string{u.Paths.StateDir, u.Paths.EtcDir, u.Paths.OptDir} {
		if options.KeepData && pathWithin(directory, u.Paths.DataDir) {
			continue
		}
		if removeErr := os.Remove(directory); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) && !isDirectoryNotEmpty(removeErr) {
			return result, removeErr
		}
	}
	if err = clearRecovery(u.Paths); err != nil {
		return result, fmt.Errorf("commit uninstall recovery checkpoint: %w", err)
	}
	return result, nil
}

func (u *UninstallManager) defaults() {
	if u.Paths.EtcDir == "" {
		u.Paths = DefaultPaths()
	}
	if u.Runner == nil {
		u.Runner = OSRunner{}
	}
	if u.Verifier == nil {
		u.Verifier = HTTPSVerifier{}
	}
	if u.Now == nil {
		u.Now = time.Now
	}
}

func isDirectoryNotEmpty(err error) bool {
	return errors.Is(err, syscall.ENOTEMPTY) || errors.Is(err, syscall.EEXIST)
}
