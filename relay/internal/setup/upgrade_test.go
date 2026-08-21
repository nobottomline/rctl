package setup

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	targetImage  = "ghcr.io/nobottomline/rctl-relay@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
	targetCaddy  = "docker.io/library/caddy@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
	targetCoturn = "docker.io/coturn/coturn@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
)

func upgradeOptions() UpgradeOptions {
	return UpgradeOptions{Version: "1.3.0", RelayImage: targetImage, CaddyImage: targetCaddy, CoturnImage: targetCoturn}
}

func createUpgradeFixture(t *testing.T) (Installer, *fakeRunner, string, []byte) {
	t.Helper()
	runner := &fakeRunner{}
	installer := testInstaller(t, runner, &fakeVerifier{})
	if _, err := installer.Install(context.Background(), validConfig(), InstallOptions{Version: "1.2.3"}); err != nil {
		t.Fatal(err)
	}
	database := filepath.Join(installer.Paths.RelayDataDir, "rctl-relay.db")
	if err := os.WriteFile(database, []byte("persistent-device-state"), 0o600); err != nil {
		t.Fatal(err)
	}
	secrets, err := os.ReadFile(installer.Paths.RelayEnv)
	if err != nil {
		t.Fatal(err)
	}
	return installer, runner, database, secrets
}

func TestUpgradePreservesSecretsAndPersistentState(t *testing.T) {
	installer, runner, database, secrets := createUpgradeFixture(t)
	manager := UpgradeManager{
		Paths: installer.Paths, Runner: runner, Verifier: &sequenceVerifier{},
		Now: func() time.Time { return time.Unix(1700002000, 0) }, Chown: func(string, int, int) error { return nil },
	}
	result, err := manager.Upgrade(context.Background(), upgradeOptions())
	if err != nil {
		t.Fatal(err)
	}
	if result.FromVersion != "1.2.3" || result.ToVersion != "1.3.0" || result.Backup == "" {
		t.Fatalf("unexpected result: %+v", result)
	}
	manifest, err := loadManifest(installer.Paths.ManifestPath)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Version != "1.3.0" || manifest.Config.Release != "1.3.0" || manifest.Config.RelayImage != targetImage || manifest.Config.CaddyImage != targetCaddy || manifest.Config.CoturnImage != targetCoturn {
		t.Fatalf("unexpected upgraded manifest: %+v", manifest)
	}
	afterSecrets, err := os.ReadFile(installer.Paths.RelayEnv)
	if err != nil || string(afterSecrets) != string(secrets) {
		t.Fatalf("relay secrets changed: err=%v", err)
	}
	state, err := os.ReadFile(database)
	if err != nil || string(state) != "persistent-device-state" {
		t.Fatalf("persistent state=%q err=%v", state, err)
	}
	if _, err := ValidateBackup(result.Backup); err != nil {
		t.Fatalf("pre-upgrade backup is invalid: %v", err)
	}
}

func TestUpgradeDryRunAndVersionChecksDoNotMutateHost(t *testing.T) {
	installer, runner, _, _ := createUpgradeFixture(t)
	manager := UpgradeManager{Paths: installer.Paths, Runner: runner, Verifier: &sequenceVerifier{}, Now: time.Now, Chown: func(string, int, int) error { return nil }}
	beforeCalls := len(runner.calls)
	options := upgradeOptions()
	options.DryRun = true
	result, err := manager.Upgrade(context.Background(), options)
	if err != nil || !result.DryRun || len(runner.calls) != beforeCalls {
		t.Fatalf("dry run result=%+v err=%v calls=%v", result, err, runner.calls[beforeCalls:])
	}
	for _, version := range []string{"1.2.3", "1.2.2", "v1.3.0", "1.03.0"} {
		options.Version = version
		if _, err := manager.Plan(options); err == nil {
			t.Fatalf("version %q was accepted", version)
		}
	}
	if len(runner.calls) != beforeCalls {
		t.Fatal("rejected version changed service state")
	}
}

func TestUpgradeAlreadyCurrentVerifiesWithoutBackup(t *testing.T) {
	runner := &fakeRunner{}
	installer := testInstaller(t, runner, &fakeVerifier{})
	cfg := validConfig()
	cfg.Release = "1.2.3"
	if _, err := installer.Install(context.Background(), cfg, InstallOptions{Version: "1.2.3"}); err != nil {
		t.Fatal(err)
	}
	beforeCalls := len(runner.calls)
	verifier := &sequenceVerifier{}
	options := UpgradeOptions{Version: "1.2.3", RelayImage: testImage, CaddyImage: testCaddy, CoturnImage: testCoturn}
	result, err := (UpgradeManager{Paths: installer.Paths, Runner: runner, Verifier: verifier, Now: time.Now, Chown: func(string, int, int) error { return nil }}).Upgrade(context.Background(), options)
	if err != nil {
		t.Fatal(err)
	}
	if !result.AlreadyCurrent || result.Backup != "" || verifier.calls != 1 {
		t.Fatalf("unexpected already-current result=%+v verificationCalls=%d", result, verifier.calls)
	}
	calls := strings.Join(runner.calls[beforeCalls:], "\n")
	if strings.Contains(calls, " stop ") || strings.Contains(calls, " pull") {
		t.Fatalf("already-current verification mutated services:\n%s", calls)
	}
}

func TestUpgradeRollsBackFailedTargetVerification(t *testing.T) {
	installer, runner, database, secrets := createUpgradeFixture(t)
	verifier := &sequenceVerifier{failAt: 2}
	manager := UpgradeManager{
		Paths: installer.Paths, Runner: runner, Verifier: verifier,
		Now: func() time.Time { return time.Unix(1700003000, 0) }, Chown: func(string, int, int) error { return nil },
	}
	result, err := manager.Upgrade(context.Background(), upgradeOptions())
	if err == nil || !strings.Contains(err.Error(), "was rolled back") {
		t.Fatalf("result=%+v err=%v", result, err)
	}
	manifest, loadErr := loadManifest(installer.Paths.ManifestPath)
	if loadErr != nil || manifest.Version != "1.2.3" || manifest.Config.RelayImage != testImage {
		t.Fatalf("rollback manifest=%+v err=%v", manifest, loadErr)
	}
	afterSecrets, readErr := os.ReadFile(installer.Paths.RelayEnv)
	if readErr != nil || string(afterSecrets) != string(secrets) {
		t.Fatalf("rollback secrets changed: %v", readErr)
	}
	state, readErr := os.ReadFile(database)
	if readErr != nil || string(state) != "persistent-device-state" {
		t.Fatalf("rollback state=%q err=%v", state, readErr)
	}
	if verifier.calls != 3 {
		t.Fatalf("verification calls=%d, expected backup, target, rollback", verifier.calls)
	}
}

func TestUpgradeWithoutTURNDoesNotRequireDiscardedTURNSecret(t *testing.T) {
	runner := &fakeRunner{}
	installer := testInstaller(t, runner, &fakeVerifier{})
	cfg := validConfig()
	cfg.EnableTURN = false
	cfg.CoturnImage = ""
	cfg.TURNExternalIP = ""
	if _, err := installer.Install(context.Background(), cfg, InstallOptions{Version: "1.2.3"}); err != nil {
		t.Fatal(err)
	}
	manager := UpgradeManager{Paths: installer.Paths, Runner: runner, Verifier: &sequenceVerifier{}, Now: time.Now, Chown: func(string, int, int) error { return nil }}
	if _, err := manager.Plan(upgradeOptions()); err != nil {
		t.Fatal(err)
	}
}
