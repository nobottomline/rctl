package setup

import (
	"bytes"
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

const recoverySchema = 1

type RecoveryState struct {
	Schema    int    `json:"schema"`
	Product   string `json:"product"`
	Operation string `json:"operation"`
	Backup    string `json:"backup,omitempty"`
	StartedAt int64  `json:"started_at"`
}

type RecoveryManager struct {
	Paths    Paths
	Runner   Runner
	Verifier PublicVerifier
	Chown    Chowner
}

func pendingRecovery(paths Paths) (RecoveryState, error) {
	if paths.EtcDir == "" {
		paths = DefaultPaths()
	}
	raw, err := readRegularFile(paths.RecoveryPath, 1<<20, 0o600)
	if err != nil {
		return RecoveryState{}, err
	}
	var state RecoveryState
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&state); err != nil {
		return state, fmt.Errorf("decode recovery checkpoint: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return state, errors.New("recovery checkpoint contains trailing data")
	}
	if state.Schema != recoverySchema || state.Product != "rctl" || state.StartedAt <= 0 {
		return state, errors.New("recovery checkpoint is incompatible")
	}
	switch state.Operation {
	case "backup", "install":
		if state.Backup != "" {
			return state, fmt.Errorf("%s recovery checkpoint must not name a rollback archive", state.Operation)
		}
	case "restore", "restore-uninstalled", "upgrade", "uninstall", "reset-admin":
		if err := validateBackupSelection(state.Backup, paths.BackupDir); err != nil {
			return state, fmt.Errorf("recovery checkpoint backup: %w", err)
		}
	default:
		return state, fmt.Errorf("unsupported recovery operation %q", state.Operation)
	}
	return state, nil
}

func ensureNoPendingRecovery(paths Paths) error {
	state, err := pendingRecovery(paths)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	return fmt.Errorf("interrupted %s operation requires rctl-setup recover first", state.Operation)
}

func beginRecovery(paths Paths, operation, backup string, now time.Time) error {
	if err := ensureNoPendingRecovery(paths); err != nil {
		return err
	}
	if err := os.MkdirAll(paths.LogDir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(paths.LogDir, 0o700); err != nil {
		return err
	}
	state := RecoveryState{Schema: recoverySchema, Product: "rctl", Operation: operation, Backup: backup, StartedAt: now.Unix()}
	return writeJSONAtomic(paths.RecoveryPath, state, 0o600)
}

func transitionRecovery(paths Paths, operation, backup string, now time.Time) error {
	state, err := pendingRecovery(paths)
	if err != nil {
		return err
	}
	if state.Operation != "backup" || state.Backup != "" {
		return errors.New("lifecycle recovery checkpoint is not a mutation backup")
	}
	if err := validateBackupSelection(backup, paths.BackupDir); err != nil {
		return err
	}
	next := RecoveryState{Schema: recoverySchema, Product: "rctl", Operation: operation, Backup: backup, StartedAt: now.Unix()}
	switch operation {
	case "restore", "upgrade", "uninstall", "reset-admin":
	default:
		return fmt.Errorf("unsupported recovery transition %q", operation)
	}
	return writeJSONAtomic(paths.RecoveryPath, next, 0o600)
}

func clearRecovery(paths Paths) error {
	if err := os.Remove(paths.RecoveryPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return syncDirectory(paths.LogDir)
}

func (r RecoveryManager) Plan() (RecoveryState, error) {
	r.defaults()
	state, err := pendingRecovery(r.Paths)
	if err != nil {
		return state, err
	}
	if state.Backup != "" {
		if _, err := ValidateBackup(state.Backup); err != nil {
			return state, fmt.Errorf("validate rollback backup: %w", err)
		}
	}
	return state, nil
}

func (r RecoveryManager) Recover(ctx context.Context) (RecoveryState, error) {
	r.defaults()
	state, err := r.Plan()
	if err != nil {
		return state, err
	}
	releaseLock, err := acquireLifecycleLock(r.Paths.LockPath)
	if err != nil {
		return state, err
	}
	defer releaseLock()
	state, err = r.Plan()
	if err != nil {
		return state, err
	}
	installer := Installer{Paths: r.Paths, Runner: r.Runner, Verifier: r.Verifier, Chown: r.Chown}
	if state.Operation == "install" {
		if info, statErr := os.Lstat(r.Paths.Compose); statErr == nil && info.Mode().IsRegular() {
			_, _ = r.Runner.Run(ctx, "docker", installer.composeArgs("down", "--remove-orphans")...)
		}
		if err := removeInterruptedInstall(r.Paths); err != nil {
			return state, err
		}
		return state, clearRecovery(r.Paths)
	}
	if state.Operation == "backup" {
		manifest, err := loadManifest(r.Paths.ManifestPath)
		if err != nil {
			return state, err
		}
		if err := validateOwnershipManifest(manifest, r.Paths); err != nil {
			return state, err
		}
		if output, startErr := r.Runner.Run(ctx, "docker", installer.composeArgs("up", "-d")...); startErr != nil {
			return state, fmt.Errorf("restart interrupted backup services: %s", commandFailure(output, startErr))
		}
		if err := installer.waitForServices(ctx, manifest.Config.EnableTURN); err != nil {
			return state, err
		}
		secrets, err := readExistingSecrets(r.Paths.RelayEnv)
		if err != nil {
			return state, err
		}
		if err := r.Verifier.Verify(ctx, manifest.Config, secrets.Admin); err != nil {
			return state, err
		}
		cleanupIncompleteBackups(r.Paths.BackupDir)
		return state, clearRecovery(r.Paths)
	}

	target, err := snapshotOwnership(state.Backup, r.Paths)
	if err != nil {
		return state, err
	}
	current := target
	if installed, loadErr := loadManifest(r.Paths.ManifestPath); loadErr == nil {
		current = installed
	} else if !errors.Is(loadErr, os.ErrNotExist) {
		// A partial manifest is untrusted; target paths still bound cleanup safely.
		current = target
	}
	if info, statErr := os.Lstat(r.Paths.Compose); statErr == nil && info.Mode().IsRegular() {
		_, _ = r.Runner.Run(ctx, "docker", installer.composeArgs("down", "--remove-orphans")...)
	}
	if _, err := applyBackup(state.Backup, current, r.Paths); err != nil {
		return state, err
	}
	if err := removeKnownManagedExtras(target, r.Paths); err != nil {
		return state, err
	}
	if err := (RestoreManager{Paths: r.Paths, Runner: r.Runner, Verifier: r.Verifier}).startAndVerify(ctx, installer, target); err != nil {
		return state, err
	}
	if state.Operation == "restore-uninstalled" {
		cleanupRetainedDirectories(filepath.Dir(r.Paths.DataDir))
	}
	if err := clearRecovery(r.Paths); err != nil {
		return state, err
	}
	return state, nil
}

func cleanupRetainedDirectories(root string) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".rctl-retained-") {
			_ = os.RemoveAll(filepath.Join(root, entry.Name()))
		}
	}
}

func removeInterruptedInstall(paths Paths) error {
	for _, name := range []string{paths.RelayEnv, paths.Compose, paths.Caddyfile, paths.Coturn, paths.PublicPackage, paths.ManifestPath} {
		if err := os.Remove(name); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	for _, directory := range []string{paths.DataDir, paths.EtcDir, paths.OptDir, paths.BackupDir} {
		if err := os.RemoveAll(directory); err != nil {
			return err
		}
	}
	return nil
}

func removeKnownManagedExtras(target OwnershipManifest, paths Paths) error {
	wanted := make(map[string]bool, len(target.Files))
	for _, file := range target.Files {
		wanted[file.Path] = true
	}
	for _, name := range []string{paths.RelayEnv, paths.Compose, paths.Caddyfile, paths.Coturn, paths.PublicPackage} {
		if wanted[name] {
			continue
		}
		if err := os.Remove(name); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

func (r *RecoveryManager) defaults() {
	if r.Paths.EtcDir == "" {
		r.Paths = DefaultPaths()
	}
	if r.Runner == nil {
		r.Runner = OSRunner{}
	}
	if r.Verifier == nil {
		r.Verifier = HTTPSVerifier{}
	}
	if r.Chown == nil {
		r.Chown = os.Chown
	}
}

func cleanupIncompleteBackups(root string) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".backup-") {
			_ = os.RemoveAll(filepath.Join(root, entry.Name()))
		}
	}
}
