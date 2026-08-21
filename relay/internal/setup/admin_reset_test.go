package setup

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

type adminResetVerifier struct {
	secrets []string
	failAt  int
}

func (v *adminResetVerifier) Verify(_ context.Context, _ Config, secret string) error {
	v.secrets = append(v.secrets, secret)
	if len(v.secrets) == v.failAt {
		return errors.New("synthetic credential verification failure")
	}
	return nil
}

func (v *adminResetVerifier) VerifyPersistence(ctx context.Context, _ Config, _ string, restart func(context.Context) error) error {
	return restart(ctx)
}

func TestAdminResetRotatesLoginAndSessionsButPreservesDeploymentIdentity(t *testing.T) {
	installer, runner, database, oldEnvironment := createUpgradeFixture(t)
	oldSecrets, err := readExistingSecrets(installer.Paths.RelayEnv)
	if err != nil {
		t.Fatal(err)
	}
	verifier := &adminResetVerifier{}
	manager := AdminResetManager{
		Paths: installer.Paths, Runner: runner, Verifier: verifier,
		Random: strings.NewReader(strings.Repeat("fedcba9876543210", 16)),
		Now:    func() time.Time { return time.Unix(1700004000, 0) },
	}
	if err := manager.Plan(); err != nil {
		t.Fatal(err)
	}
	result, err := manager.Reset(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	if result.AdminSecret == "" || result.AdminSecret == oldSecrets.Admin || result.Backup == "" {
		t.Fatalf("unexpected reset result: %+v", result)
	}
	newSecrets, err := readExistingSecrets(installer.Paths.RelayEnv)
	if err != nil {
		t.Fatal(err)
	}
	if newSecrets.Admin != result.AdminSecret || newSecrets.Admin == oldSecrets.Admin || newSecrets.Session == oldSecrets.Session || newSecrets.TURN != oldSecrets.TURN {
		t.Fatalf("unexpected rotated secret set: admin_changed=%t session_changed=%t turn_preserved=%t", newSecrets.Admin != oldSecrets.Admin, newSecrets.Session != oldSecrets.Session, newSecrets.TURN == oldSecrets.TURN)
	}
	if raw, err := os.ReadFile(database); err != nil || string(raw) != "persistent-device-state" {
		t.Fatalf("persistent state=%q err=%v", raw, err)
	}
	manifest, err := loadManifest(installer.Paths.ManifestPath)
	if err != nil || manifest.Version != "1.2.3" || manifest.Config.RelayImage != testImage {
		t.Fatalf("deployment identity changed: manifest=%+v err=%v", manifest, err)
	}
	if err := verifyOwnedFiles(manifest); err != nil {
		t.Fatalf("updated ownership manifest: %v", err)
	}
	if len(verifier.secrets) != 2 || verifier.secrets[0] != oldSecrets.Admin || verifier.secrets[1] != newSecrets.Admin {
		t.Fatalf("verified secrets=%v", verifier.secrets)
	}
	if calls := strings.Join(runner.calls, "\n"); !strings.Contains(calls, "up -d --force-recreate relay") {
		t.Fatalf("relay was not recreated with the new environment:\n%s", calls)
	}
	if string(oldEnvironment) == string(mustReadSetupFile(t, installer.Paths.RelayEnv)) {
		t.Fatal("relay environment did not change")
	}
	if _, err := ValidateBackup(result.Backup); err != nil {
		t.Fatalf("pre-reset backup: %v", err)
	}
}

func TestAdminResetRollsBackFailedNewCredentialVerification(t *testing.T) {
	installer, runner, database, oldEnvironment := createUpgradeFixture(t)
	verifier := &adminResetVerifier{failAt: 2}
	manager := AdminResetManager{
		Paths: installer.Paths, Runner: runner, Verifier: verifier,
		Random: strings.NewReader(strings.Repeat("abcdef0123456789", 16)),
		Now:    func() time.Time { return time.Unix(1700004100, 0) },
	}
	result, err := manager.Reset(context.Background(), false)
	if err == nil || !strings.Contains(err.Error(), "was rolled back") || result.Backup == "" || result.AdminSecret != "" {
		t.Fatalf("result=%+v err=%v", result, err)
	}
	if raw := mustReadSetupFile(t, installer.Paths.RelayEnv); string(raw) != string(oldEnvironment) {
		t.Fatal("failed reset did not restore the exact relay environment")
	}
	if raw, readErr := os.ReadFile(database); readErr != nil || string(raw) != "persistent-device-state" {
		t.Fatalf("rollback state=%q err=%v", raw, readErr)
	}
	if len(verifier.secrets) != 3 || verifier.secrets[0] != verifier.secrets[2] {
		t.Fatalf("verification sequence did not return to old credentials: %v", verifier.secrets)
	}
}

func TestAdminResetDryRunDoesNotGenerateOrMutate(t *testing.T) {
	installer, runner, _, oldEnvironment := createUpgradeFixture(t)
	beforeCalls := len(runner.calls)
	result, err := (AdminResetManager{
		Paths: installer.Paths, Runner: runner, Verifier: &adminResetVerifier{},
		Random: strings.NewReader("too short and must not be read"),
	}).Reset(context.Background(), true)
	if err != nil || !result.DryRun || result.AdminSecret != "" || result.Backup != "" {
		t.Fatalf("result=%+v err=%v", result, err)
	}
	if len(runner.calls) != beforeCalls || string(mustReadSetupFile(t, installer.Paths.RelayEnv)) != string(oldEnvironment) {
		t.Fatal("dry run mutated the deployment")
	}
}

func TestAdminResetGenerationFailureDoesNotEnterMaintenance(t *testing.T) {
	installer, runner, _, oldEnvironment := createUpgradeFixture(t)
	beforeCalls := len(runner.calls)
	result, err := (AdminResetManager{
		Paths: installer.Paths, Runner: runner, Verifier: &adminResetVerifier{},
		Random: strings.NewReader("insufficient entropy"),
	}).Reset(context.Background(), false)
	if err == nil || result.Backup != "" || result.AdminSecret != "" {
		t.Fatalf("result=%+v err=%v", result, err)
	}
	if len(runner.calls) != beforeCalls {
		t.Fatalf("credential generation failure ran Docker commands: %v", runner.calls[beforeCalls:])
	}
	if string(mustReadSetupFile(t, installer.Paths.RelayEnv)) != string(oldEnvironment) {
		t.Fatal("credential generation failure changed relay.env")
	}
	if _, statErr := os.Lstat(installer.Paths.RecoveryPath); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("credential generation failure created recovery state: %v", statErr)
	}
}

func mustReadSetupFile(t *testing.T, path string) []byte {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
