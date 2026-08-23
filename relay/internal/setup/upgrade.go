package setup

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type UpgradeOptions struct {
	DryRun                   bool
	Version                  string
	RelayImage               string
	CaddyImage               string
	CoturnImage              string
	PublicPackageSource      string
	ExpectedConfig           *Config
	DefaultUpdateManifestURL string
}

type UpgradeResult struct {
	DryRun         bool
	AlreadyCurrent bool
	FromVersion    string
	ToVersion      string
	Backup         string
	Files          []string
}

type UpgradeManager struct {
	Paths    Paths
	Runner   Runner
	Verifier PublicVerifier
	Now      func() time.Time
	Chown    Chowner
	Progress ProgressFunc
}

type upgradePlan struct {
	current        OwnershipManifest
	target         OwnershipManifest
	bundle         Bundle
	secrets        Secrets
	alreadyCurrent bool
}

func (u UpgradeManager) Plan(options UpgradeOptions) (UpgradeResult, error) {
	u.defaults()
	plan, err := u.prepare(options)
	if err != nil {
		return UpgradeResult{}, err
	}
	return UpgradeResult{
		DryRun: true, AlreadyCurrent: plan.alreadyCurrent, FromVersion: plan.current.Version, ToVersion: plan.target.Version,
		Files: ownedPaths(plan.target.Files),
	}, nil
}

func (u UpgradeManager) Upgrade(ctx context.Context, options UpgradeOptions) (result UpgradeResult, err error) {
	u.defaults()
	plan, err := u.prepare(options)
	if err != nil {
		return result, err
	}
	result = UpgradeResult{AlreadyCurrent: plan.alreadyCurrent, FromVersion: plan.current.Version, ToVersion: plan.target.Version, Files: ownedPaths(plan.target.Files)}
	if options.DryRun {
		result.DryRun = true
		return result, nil
	}
	if plan.alreadyCurrent {
		u.progress("Verifying the already-current relay deployment")
		installer := Installer{Paths: u.Paths, Runner: u.Runner, Verifier: u.Verifier, Chown: u.Chown, Progress: u.Progress}
		if err := installer.verifyServices(ctx, plan.current.Config, plan.secrets.Admin, false); err != nil {
			return result, fmt.Errorf("current deployment verification failed: %w", err)
		}
		return result, nil
	}

	u.progress("Validating and pulling the target release")
	if err := u.validateCandidates(ctx, plan); err != nil {
		return result, err
	}
	u.progress("Creating and verifying the pre-upgrade backup")
	mutation, err := (BackupManager{Paths: u.Paths, Runner: u.Runner, Verifier: u.Verifier, Now: u.Now}).BeginMutation(ctx, "upgrade", plan.current)
	result.Backup = mutation.Backup
	if err != nil {
		return result, fmt.Errorf("create pre-upgrade mutation backup: %w", err)
	}
	defer mutation.Release()
	backupManifest := mutation.Manifest

	installer := Installer{Paths: u.Paths, Runner: u.Runner, Verifier: u.Verifier, Chown: u.Chown, Progress: u.Progress}

	applied := false
	defer func() {
		if err == nil || !applied {
			return
		}
		recoveryCtx, cancel := lifecycleRecoveryContext()
		defer cancel()
		rollbackErr := stopForStateReplacement(recoveryCtx, u.Runner, installer)
		if rollbackErr == nil {
			_, rollbackErr = applyBackup(result.Backup, plan.target, u.Paths)
		}
		if rollbackErr == nil {
			rollbackErr = (RestoreManager{Paths: u.Paths, Runner: u.Runner, Verifier: u.Verifier}).startAndVerify(recoveryCtx, installer, backupManifest)
		}
		if rollbackErr != nil {
			err = fmt.Errorf("upgrade failed: %v; automatic rollback also failed: %w", err, rollbackErr)
			return
		}
		if clearErr := clearRecovery(u.Paths); clearErr != nil {
			err = fmt.Errorf("upgrade failed and was rolled back, but recovery checkpoint remains: %v: %w", err, clearErr)
			return
		}
		err = fmt.Errorf("upgrade failed and was rolled back: %w", err)
	}()

	applied = true
	u.progress("Applying the target release")
	if err = writeUpgradeBundle(plan.bundle, plan.current, plan.target, u.Paths); err != nil {
		return result, err
	}
	if err = applyRuntimeOwnership(plan.target.Config, u.Paths, u.Chown); err != nil {
		return result, err
	}
	if err = installer.verifyServices(ctx, plan.target.Config, plan.secrets.Admin, true); err != nil {
		return result, fmt.Errorf("upgraded deployment verification failed: %w", err)
	}
	if err = clearRecovery(u.Paths); err != nil {
		return result, fmt.Errorf("commit upgrade recovery checkpoint: %w", err)
	}
	u.progress("Upgrade committed after runtime verification")
	return result, nil
}

func (u UpgradeManager) progress(message string) {
	if u.Progress != nil {
		u.Progress(message)
	}
}

func (u *UpgradeManager) defaults() {
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
	if u.Chown == nil {
		u.Chown = os.Chown
	}
}

func (u UpgradeManager) prepare(options UpgradeOptions) (upgradePlan, error) {
	if err := ensureNoPendingRecovery(u.Paths); err != nil {
		return upgradePlan{}, err
	}
	current, err := loadManifest(u.Paths.ManifestPath)
	if err != nil {
		return upgradePlan{}, err
	}
	if err := validateOwnershipManifest(current, u.Paths); err != nil {
		return upgradePlan{}, err
	}
	if err := verifyOwnedFiles(current); err != nil {
		return upgradePlan{}, err
	}
	if options.ExpectedConfig != nil {
		if err := options.ExpectedConfig.Validate(); err != nil {
			return upgradePlan{}, fmt.Errorf("expected bootstrap configuration: %w", err)
		}
		if !sameDeploymentIdentity(current.Config, *options.ExpectedConfig) {
			return upgradePlan{}, errors.New("supplied bootstrap configuration differs from the installed deployment")
		}
	}
	comparison, err := compareReleases(current.Version, options.Version)
	if err != nil {
		return upgradePlan{}, err
	}
	secrets, err := readExistingSecrets(u.Paths.RelayEnv)
	if err != nil {
		return upgradePlan{}, err
	}
	targetConfig := current.Config
	targetConfig.Release = options.Version
	targetConfig.RelayImage = options.RelayImage
	targetConfig.CaddyImage = options.CaddyImage
	if targetConfig.DeviceUpdateChannel == "" {
		if targetConfig.UpdateManifestURL != "" {
			targetConfig.DeviceUpdateChannel = UpdateChannelCustom
		} else if options.DefaultUpdateManifestURL != "" {
			targetConfig.DeviceUpdateChannel = UpdateChannelStable
			targetConfig.UpdateManifestURL = options.DefaultUpdateManifestURL
		}
	}
	if options.ExpectedConfig != nil {
		targetConfig.DeviceUpdateChannel = options.ExpectedConfig.DeviceUpdateChannel
		targetConfig.UpdateManifestURL = options.ExpectedConfig.UpdateManifestURL
	}
	if targetConfig.DeviceUpdateChannel == UpdateChannelStable && options.DefaultUpdateManifestURL != "" {
		targetConfig.UpdateManifestURL = options.DefaultUpdateManifestURL
	}
	if targetConfig.EnableTURN {
		targetConfig.CoturnImage = options.CoturnImage
	}
	if err := targetConfig.Validate(); err != nil {
		return upgradePlan{}, fmt.Errorf("target configuration: %w", err)
	}
	bundle, err := RenderDedicatedBundleAt(targetConfig, secrets, u.Paths)
	if err != nil {
		return upgradePlan{}, err
	}
	if targetConfig.DevicePackages {
		packageData, packageInfo, packageErr := readPublicPackageSource(options.PublicPackageSource)
		if packageErr != nil {
			return upgradePlan{}, packageErr
		}
		if packageInfo.Version != options.Version {
			return upgradePlan{}, fmt.Errorf("public device package version %q does not match target release %q", packageInfo.Version, options.Version)
		}
		bundle.Files = append(bundle.Files, File{Path: u.Paths.PublicPackage, Mode: 0o644, Content: packageData})
	} else if options.PublicPackageSource != "" {
		return upgradePlan{}, errors.New("installed relay does not have device package generation enabled")
	}
	now := u.Now().Unix()
	target := manifestFor(targetConfig, bundle, options.Version, current.CreatedAt, now)
	alreadyCurrent := comparison == 0
	if alreadyCurrent && (!configsEqual(current.Config, target.Config) || !ownedFilesEqual(current.Files, target.Files)) {
		return upgradePlan{}, errors.New("installed files differ from artifacts carrying the same release version")
	}
	return upgradePlan{current: current, target: target, bundle: bundle, secrets: secrets, alreadyCurrent: alreadyCurrent}, nil
}

func sameDeploymentIdentity(current, expected Config) bool {
	return current.Schema == expected.Schema &&
		current.PublicURL == expected.PublicURL &&
		current.Profile == expected.Profile &&
		current.TURNExternalIP == expected.TURNExternalIP &&
		current.EnableTURN == expected.EnableTURN &&
		current.ACMEEmail == expected.ACMEEmail &&
		current.DevicePackages == expected.DevicePackages
}

func (u UpgradeManager) validateCandidates(ctx context.Context, plan upgradePlan) error {
	temporary, err := os.MkdirTemp("", "rctl-upgrade-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temporary)
	compose := bundleFile(plan.bundle, u.Paths.Compose)
	caddy := bundleFile(plan.bundle, u.Paths.Caddyfile)
	if compose == nil || caddy == nil {
		return errors.New("target bundle is missing required deployment files")
	}
	composePath := filepath.Join(temporary, "compose.json")
	caddyPath := filepath.Join(temporary, "Caddyfile")
	if err := os.WriteFile(composePath, compose.Content, 0o600); err != nil {
		return err
	}
	if err := os.WriteFile(caddyPath, caddy.Content, 0o600); err != nil {
		return err
	}
	composeArgs := []string{"compose", "--project-name", "rctl", "--file", composePath}
	if output, err := u.Runner.Run(ctx, "docker", append(composeArgs, "config", "--quiet")...); err != nil {
		return fmt.Errorf("target compose validation: %s", commandFailure(output, err))
	}
	if output, err := u.Runner.Run(ctx, "docker", "run", "--rm", "--network", "none", "-v", caddyPath+":/etc/caddy/Caddyfile:ro", plan.target.Config.CaddyImage, "caddy", "validate", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"); err != nil {
		return fmt.Errorf("target Caddy validation: %s", commandFailure(output, err))
	}
	if output, err := u.Runner.Run(ctx, "docker", append(composeArgs, "pull")...); err != nil {
		return fmt.Errorf("target image pull: %s", commandFailure(output, err))
	}
	return nil
}

func bundleFile(bundle Bundle, path string) *File {
	for index := range bundle.Files {
		if bundle.Files[index].Path == path {
			return &bundle.Files[index]
		}
	}
	return nil
}

func writeUpgradeBundle(bundle Bundle, current, target OwnershipManifest, paths Paths) error {
	for _, file := range bundle.Files {
		if err := writeFileAtomic(file.Path, file.Content, os.FileMode(file.Mode)); err != nil {
			return err
		}
	}
	if err := writeJSONAtomic(paths.ManifestPath, target, 0o600); err != nil {
		return err
	}
	targetPaths := make(map[string]bool, len(target.Files))
	for _, file := range target.Files {
		targetPaths[file.Path] = true
	}
	for _, file := range current.Files {
		if !targetPaths[file.Path] {
			if err := os.Remove(file.Path); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
		}
	}
	return verifyOwnedFiles(target)
}

func compareReleases(current, target string) (int, error) {
	currentParts, err := parseRelease(current)
	if err != nil {
		return 0, fmt.Errorf("installed release %q is not upgrade-compatible: %w", current, err)
	}
	targetParts, err := parseRelease(target)
	if err != nil {
		return 0, fmt.Errorf("target release %q is invalid: %w", target, err)
	}
	for index := range currentParts {
		if targetParts[index] > currentParts[index] {
			return 1, nil
		}
		if targetParts[index] < currentParts[index] {
			return 0, errors.New("target release is older than the installed release; use restore for rollback")
		}
	}
	return 0, nil
}

func ownedFilesEqual(a, b []OwnedFile) bool {
	if len(a) != len(b) {
		return false
	}
	for index := range a {
		if a[index] != b[index] {
			return false
		}
	}
	return true
}

func parseRelease(value string) ([3]uint64, error) {
	var result [3]uint64
	parts := strings.Split(value, ".")
	if len(parts) != len(result) {
		return result, errors.New("expected MAJOR.MINOR.PATCH")
	}
	for index, part := range parts {
		if part == "" || (len(part) > 1 && part[0] == '0') {
			return result, errors.New("version components must be canonical decimal numbers")
		}
		parsed, err := strconv.ParseUint(part, 10, 63)
		if err != nil {
			return result, errors.New("version components must be canonical decimal numbers")
		}
		result[index] = parsed
	}
	return result, nil
}
