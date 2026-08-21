package setup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"time"
)

type AdminResetResult struct {
	DryRun      bool
	Backup      string
	AdminSecret string
}

type AdminResetManager struct {
	Paths    Paths
	Runner   Runner
	Verifier PublicVerifier
	Random   io.Reader
	Now      func() time.Time
}

func (m AdminResetManager) Plan() error {
	m.defaults()
	if err := ensureNoPendingRecovery(m.Paths); err != nil {
		return err
	}
	manifest, err := loadManifest(m.Paths.ManifestPath)
	if err != nil {
		return err
	}
	if err := validateOwnershipManifest(manifest, m.Paths); err != nil {
		return err
	}
	if err := verifyOwnedFiles(manifest); err != nil {
		return err
	}
	_, err = readExistingSecrets(m.Paths.RelayEnv)
	return err
}

func (m AdminResetManager) Reset(ctx context.Context, dryRun bool) (result AdminResetResult, err error) {
	m.defaults()
	if err := m.Plan(); err != nil {
		return result, err
	}
	if dryRun {
		result.DryRun = true
		return result, nil
	}

	expected, err := loadManifest(m.Paths.ManifestPath)
	if err != nil {
		return result, err
	}
	oldSecrets, err := readExistingSecrets(m.Paths.RelayEnv)
	if err != nil {
		return result, err
	}
	generated, err := GenerateSecrets(m.Random)
	if err != nil {
		return result, err
	}
	newSecrets := Secrets{Admin: generated.Admin, Session: generated.Session, TURN: oldSecrets.TURN}
	bundle, err := RenderDedicatedBundleAt(expected.Config, newSecrets, m.Paths)
	if err != nil {
		return result, err
	}
	environment := bundleFile(bundle, m.Paths.RelayEnv)
	if environment == nil {
		return result, errors.New("credential reset bundle is missing relay.env")
	}
	target := expected
	target.Files = append([]OwnedFile(nil), expected.Files...)
	target.UpdatedAt = m.Now().Unix()
	digest := sha256.Sum256(environment.Content)
	updated := false
	for index := range target.Files {
		if target.Files[index].Path == m.Paths.RelayEnv {
			target.Files[index].SHA256 = hex.EncodeToString(digest[:])
			updated = true
			break
		}
	}
	if !updated {
		return result, errors.New("ownership manifest does not contain relay.env")
	}
	mutation, err := (BackupManager{Paths: m.Paths, Runner: m.Runner, Verifier: m.Verifier, Now: m.Now}).BeginMutation(ctx, "reset-admin", expected)
	result.Backup = mutation.Backup
	if err != nil {
		return result, fmt.Errorf("create pre-reset mutation backup: %w", err)
	}
	defer mutation.Release()
	current := mutation.Manifest
	backupManifest := mutation.Manifest

	installer := Installer{Paths: m.Paths, Runner: m.Runner, Verifier: m.Verifier}
	defer func() {
		if err == nil {
			return
		}
		recoveryCtx, cancel := lifecycleRecoveryContext()
		defer cancel()
		_, rollbackErr := applyBackup(result.Backup, target, m.Paths)
		if rollbackErr == nil {
			rollbackErr = (RestoreManager{Paths: m.Paths, Runner: m.Runner, Verifier: m.Verifier}).startAndVerify(recoveryCtx, installer, backupManifest)
		}
		if rollbackErr != nil {
			err = fmt.Errorf("admin credential reset failed: %v; automatic rollback also failed: %w", err, rollbackErr)
			return
		}
		if clearErr := clearRecovery(m.Paths); clearErr != nil {
			err = fmt.Errorf("admin credential reset failed and was rolled back, but recovery checkpoint remains: %v: %w", err, clearErr)
			return
		}
		err = fmt.Errorf("admin credential reset failed and was rolled back: %w", err)
	}()

	if err = writeFileAtomic(m.Paths.RelayEnv, environment.Content, os.FileMode(environment.Mode)); err != nil {
		return result, err
	}
	if err = writeJSONAtomic(m.Paths.ManifestPath, target, 0o600); err != nil {
		return result, err
	}
	if output, restartErr := m.Runner.Run(ctx, "docker", installer.composeArgs("up", "-d", "--force-recreate", "relay")...); restartErr != nil {
		return result, fmt.Errorf("restart relay with new credentials: %s", commandFailure(output, restartErr))
	}
	if output, startErr := m.Runner.Run(ctx, "docker", installer.composeArgs("up", "-d")...); startErr != nil {
		return result, fmt.Errorf("restart relay edge services: %s", commandFailure(output, startErr))
	}
	if err = installer.waitForServices(ctx, current.Config.EnableTURN); err != nil {
		return result, err
	}
	if err = m.Verifier.Verify(ctx, current.Config, newSecrets.Admin); err != nil {
		return result, fmt.Errorf("verify new admin credentials: %w", err)
	}
	restart := func(restartCtx context.Context) error {
		if output, restartErr := m.Runner.Run(restartCtx, "docker", installer.composeArgs("restart", "relay")...); restartErr != nil {
			return fmt.Errorf("admin session persistence restart: %s", commandFailure(output, restartErr))
		}
		return installer.waitForServices(restartCtx, current.Config.EnableTURN)
	}
	if err = m.Verifier.VerifyPersistence(ctx, current.Config, newSecrets.Admin, restart); err != nil {
		return result, fmt.Errorf("verify new admin session persistence: %w", err)
	}
	if err = clearRecovery(m.Paths); err != nil {
		return result, fmt.Errorf("commit admin credential reset: %w", err)
	}
	result.AdminSecret = newSecrets.Admin
	return result, nil
}

func (m *AdminResetManager) defaults() {
	if m.Paths.EtcDir == "" {
		m.Paths = DefaultPaths()
	}
	if m.Runner == nil {
		m.Runner = OSRunner{}
	}
	if m.Verifier == nil {
		m.Verifier = HTTPSVerifier{}
	}
	if m.Now == nil {
		m.Now = time.Now
	}
}
