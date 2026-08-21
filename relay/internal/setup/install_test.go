package setup

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

type fakeRunner struct {
	calls        []string
	failAt       int
	failContains string
}

func (r *fakeRunner) Run(_ context.Context, name string, args ...string) (string, error) {
	call := name + " " + strings.Join(args, " ")
	r.calls = append(r.calls, call)
	if r.failContains != "" && strings.Contains(call, r.failContains) {
		return "synthetic failure", errors.New("exit 1")
	}
	if r.failAt > 0 && len(r.calls) == r.failAt {
		return "synthetic failure", errors.New("exit 1")
	}
	if len(args) > 0 && args[len(args)-1] == "json" {
		return strings.Join([]string{
			`{"Service":"relay","State":"running","Health":"healthy"}`,
			`{"Service":"caddy","State":"running","Health":""}`,
			`{"Service":"coturn","State":"running","Health":"healthy"}`,
		}, "\n"), nil
	}
	return "ok", nil
}

func TestComposeServiceStateRequiresHealthyRuntime(t *testing.T) {
	states, err := parseComposePS(strings.Join([]string{
		`{"Service":"relay","State":"running","Health":"healthy"}`,
		`{"Service":"caddy","State":"running","Health":""}`,
		`{"Service":"coturn","State":"running","Health":"unhealthy"}`,
	}, "\n"))
	if err != nil {
		t.Fatal(err)
	}
	if err := requireHealthyServices(states, true); err == nil || !strings.Contains(err.Error(), "coturn health is unhealthy") {
		t.Fatalf("unhealthy TURN result: %v", err)
	}
	if err := requireHealthyServices(states, false); err != nil {
		t.Fatalf("disabled TURN affected service readiness: %v", err)
	}
}

func TestComposeServiceStateAcceptsJSONArrayAndRejectsDuplicates(t *testing.T) {
	states, err := parseComposePS(`[{"Service":"relay","State":"running","Health":"healthy"},{"Service":"caddy","State":"running","Health":""}]`)
	if err != nil || len(states) != 2 {
		t.Fatalf("array state=%v err=%v", states, err)
	}
	if _, err := parseComposePS("{\"Service\":\"relay\",\"State\":\"running\"}\n{\"Service\":\"relay\",\"State\":\"running\"}"); err == nil || !strings.Contains(err.Error(), "multiple containers") {
		t.Fatalf("duplicate service result: %v", err)
	}
}

type fakeVerifier struct {
	calls            int
	persistenceCalls int
	err              error
}

func (v *fakeVerifier) Verify(context.Context, Config, string) error {
	v.calls++
	return v.err
}

func (v *fakeVerifier) VerifyPersistence(ctx context.Context, _ Config, _ string, restart func(context.Context) error) error {
	v.persistenceCalls++
	if v.err != nil {
		return v.err
	}
	return restart(ctx)
}

func testInstaller(t *testing.T, runner *fakeRunner, verifier *fakeVerifier) Installer {
	t.Helper()
	root := t.TempDir()
	return Installer{
		Paths: PathsUnder(root), Runner: runner, Verifier: verifier,
		Random: strings.NewReader(strings.Repeat("0123456789abcdef", 16)),
		Now:    func() time.Time { return time.Unix(1700000000, 0) },
		Chown:  func(string, int, int) error { return nil },
	}
}

func TestInstallerFreshAndIdempotent(t *testing.T) {
	runner := &fakeRunner{}
	verifier := &fakeVerifier{}
	installer := testInstaller(t, runner, verifier)
	result, err := installer.Install(context.Background(), validConfig(), InstallOptions{Version: "1.0.0"})
	if err != nil {
		t.Fatal(err)
	}
	if !result.Fresh || len(result.AdminSecret) < 48 || verifier.calls != 1 || verifier.persistenceCalls != 1 {
		t.Fatalf("unexpected fresh result: %#v calls=%d persistence=%d", result, verifier.calls, verifier.persistenceCalls)
	}
	for _, path := range []string{installer.Paths.ManifestPath, installer.Paths.RelayEnv, installer.Paths.Compose, installer.Paths.Caddyfile, installer.Paths.Coturn} {
		if _, err := os.Stat(path); err != nil {
			t.Errorf("missing installed file %s: %v", path, err)
		}
	}
	result, err = installer.Install(context.Background(), validConfig(), InstallOptions{Version: "1.0.0"})
	if err != nil {
		t.Fatal(err)
	}
	if result.Fresh || result.AdminSecret != "" || verifier.calls != 2 || verifier.persistenceCalls != 1 {
		t.Fatalf("idempotent install leaked/regenerated credentials: %#v calls=%d", result, verifier.calls)
	}
}

func TestInstallerAppliesRuntimeOwnership(t *testing.T) {
	runner := &fakeRunner{}
	verifier := &fakeVerifier{}
	installer := testInstaller(t, runner, verifier)
	type ownership struct {
		path     string
		uid, gid int
	}
	var calls []ownership
	installer.Chown = func(path string, uid, gid int) error {
		calls = append(calls, ownership{path: path, uid: uid, gid: gid})
		return nil
	}
	if _, err := installer.Install(context.Background(), validConfig(), InstallOptions{Version: "1.0.0"}); err != nil {
		t.Fatal(err)
	}
	want := []ownership{
		{path: installer.Paths.RelayDataDir, uid: relayRuntimeUID, gid: relayRuntimeGID},
		{path: installer.Paths.Coturn, uid: coturnRuntimeUID, gid: coturnRuntimeGID},
	}
	if len(calls) != len(want) {
		t.Fatalf("ownership calls=%+v", calls)
	}
	for index := range want {
		if calls[index] != want[index] {
			t.Fatalf("ownership call %d=%+v, want %+v", index, calls[index], want[index])
		}
	}
}

func TestInstallerDoesNotChownDisabledTURNConfig(t *testing.T) {
	installer := testInstaller(t, &fakeRunner{}, &fakeVerifier{})
	var paths []string
	installer.Chown = func(path string, _, _ int) error {
		paths = append(paths, path)
		return nil
	}
	cfg := validConfig()
	cfg.EnableTURN = false
	cfg.CoturnImage = ""
	cfg.TURNExternalIP = ""
	if _, err := installer.Install(context.Background(), cfg, InstallOptions{Version: "1.0.0"}); err != nil {
		t.Fatal(err)
	}
	if len(paths) != 1 || paths[0] != installer.Paths.RelayDataDir {
		t.Fatalf("unexpected ownership calls: %v", paths)
	}
}

func TestInstallerDryRunDoesNotMutateFilesystem(t *testing.T) {
	installer := testInstaller(t, &fakeRunner{}, &fakeVerifier{})
	result, err := installer.Install(context.Background(), validConfig(), InstallOptions{DryRun: true})
	if err != nil {
		t.Fatal(err)
	}
	if !result.DryRun || len(result.Files) == 0 {
		t.Fatalf("unexpected dry-run result: %#v", result)
	}
	for _, path := range []string{installer.Paths.LockPath, installer.Paths.EtcDir, installer.Paths.OptDir, installer.Paths.DataDir} {
		if _, statErr := os.Lstat(path); !errors.Is(statErr, os.ErrNotExist) {
			t.Errorf("dry-run mutated %s: %v", path, statErr)
		}
	}
}

func TestInstallerRequiresValidPublicPackageBeforeMutation(t *testing.T) {
	installer := testInstaller(t, &fakeRunner{}, &fakeVerifier{})
	cfg := validConfig()
	cfg.DevicePackages = true
	if _, err := installer.Install(context.Background(), cfg, InstallOptions{DryRun: true}); err == nil || !strings.Contains(err.Error(), "public device package is required") {
		t.Fatalf("missing package result: %v", err)
	}
	invalid := filepath.Join(t.TempDir(), "invalid.deb")
	if err := os.WriteFile(invalid, []byte("not a deb"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := installer.Install(context.Background(), cfg, InstallOptions{DryRun: true, PublicPackageSource: invalid}); err == nil || !strings.Contains(err.Error(), "validate public device package") {
		t.Fatalf("invalid package result: %v", err)
	}
	for _, path := range []string{installer.Paths.LockPath, installer.Paths.EtcDir, installer.Paths.OptDir, installer.Paths.DataDir} {
		if _, statErr := os.Lstat(path); !errors.Is(statErr, os.ErrNotExist) {
			t.Errorf("package validation failure mutated %s: %v", path, statErr)
		}
	}
}

func TestBackupCreatesVerifiedRootOnlySnapshot(t *testing.T) {
	runner := &fakeRunner{}
	verifier := &fakeVerifier{}
	installer := testInstaller(t, runner, verifier)
	if _, err := installer.Install(context.Background(), validConfig(), InstallOptions{Version: "1.2.3"}); err != nil {
		t.Fatal(err)
	}
	database := filepath.Join(installer.Paths.RelayDataDir, "rctl-relay.db")
	if err := os.WriteFile(database, []byte("sqlite fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	manager := BackupManager{Paths: installer.Paths, Runner: runner, Verifier: verifier, Now: func() time.Time { return time.Unix(1700000100, 0) }}
	callCount := len(runner.calls)
	if sources, err := manager.DryRun(); err != nil || len(sources) == 0 {
		t.Fatalf("backup dry run: sources=%v err=%v", sources, err)
	}
	if len(runner.calls) != callCount {
		t.Fatal("backup dry run changed service state")
	}
	name, err := manager.Create(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !pathWithin(name, installer.Paths.BackupDir) {
		t.Fatalf("backup escaped backup root: %s", name)
	}
	info, err := os.Stat(name)
	if err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("backup directory mode=%v err=%v", info, err)
	}
	metadata, err := loadBackupMetadata(name)
	if err != nil {
		t.Fatal(err)
	}
	if metadata.Release != "1.2.3" || len(metadata.Entries) == 0 {
		t.Fatalf("unexpected backup metadata: %+v", metadata)
	}
	backedUpDB := filepath.Join(name, "root", strings.TrimPrefix(database, string(filepath.Separator)))
	if raw, err := os.ReadFile(backedUpDB); err != nil || string(raw) != "sqlite fixture" {
		t.Fatalf("database snapshot missing: %q err=%v", raw, err)
	}
	calls := strings.Join(runner.calls, "\n")
	if !strings.Contains(calls, " stop relay caddy") || !strings.Contains(calls, " up -d relay caddy") {
		t.Fatalf("backup did not bracket snapshot with service lifecycle:\n%s", calls)
	}
	if err := os.WriteFile(backedUpDB, []byte("tampered"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ValidateBackup(name); err == nil || !strings.Contains(err.Error(), "digest differs") {
		t.Fatalf("tampered backup validation: %v", err)
	}
}

func TestBackupCopyPreservesModeUnderRestrictiveUmask(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	if err := os.WriteFile(source, []byte("fixture"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(source, 0o644); err != nil {
		t.Fatal(err)
	}

	previous := syscall.Umask(0o077)
	defer syscall.Umask(previous)
	if _, err := copyRegularFile(source, destination, 0o644, os.Getuid(), os.Getgid()); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(destination)
	if err != nil || info.Mode().Perm() != 0o644 {
		t.Fatalf("destination mode=%v err=%v", info, err)
	}
}

func TestBackupRejectsSymlinkAndRestartsServices(t *testing.T) {
	runner := &fakeRunner{}
	installer := testInstaller(t, runner, &fakeVerifier{})
	if _, err := installer.Install(context.Background(), validConfig(), InstallOptions{Version: "1.2.3"}); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/etc/passwd", filepath.Join(installer.Paths.RelayDataDir, "escape")); err != nil {
		t.Fatal(err)
	}
	_, err := (BackupManager{Paths: installer.Paths, Runner: runner, Verifier: &fakeVerifier{}}).Create(context.Background())
	if err == nil || !strings.Contains(err.Error(), "non-regular") {
		t.Fatalf("symlink backup result: %v", err)
	}
	if calls := strings.Join(runner.calls, "\n"); !strings.Contains(calls, " up -d relay caddy") {
		t.Fatalf("services were not restarted after backup failure:\n%s", calls)
	}
}

func TestInstallerRefusesForeignState(t *testing.T) {
	installer := testInstaller(t, &fakeRunner{}, &fakeVerifier{})
	if err := os.MkdirAll(installer.Paths.EtcDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := installer.Install(context.Background(), validConfig(), InstallOptions{}); err == nil || !strings.Contains(err.Error(), "unowned") {
		t.Fatalf("unexpected result: %v", err)
	}
}

func TestInstallerRollsBackFailedFreshInstallAndRedactsJournal(t *testing.T) {
	runner := &fakeRunner{failAt: 4}
	installer := testInstaller(t, runner, &fakeVerifier{})
	_, err := installer.Install(context.Background(), validConfig(), InstallOptions{})
	if err == nil {
		t.Fatal("expected install failure")
	}
	for _, path := range []string{installer.Paths.EtcDir, installer.Paths.OptDir, installer.Paths.DataDir, installer.Paths.ManifestPath} {
		if _, statErr := os.Stat(path); !errors.Is(statErr, os.ErrNotExist) {
			t.Errorf("rollback retained %s: %v", path, statErr)
		}
	}
	entries, readErr := os.ReadDir(installer.Paths.LogDir)
	if readErr != nil || len(entries) != 1 {
		t.Fatalf("rollback journal missing: entries=%v err=%v", entries, readErr)
	}
	raw, _ := os.ReadFile(filepath.Join(installer.Paths.LogDir, entries[0].Name()))
	if !strings.Contains(string(raw), `"status": "rolled_back"`) || strings.Contains(string(raw), "0123456789abcdef") {
		t.Fatalf("journal status/redaction invalid: %s", raw)
	}
	runner.failAt = 0
	result, retryErr := installer.Install(context.Background(), validConfig(), InstallOptions{Version: "1.0.0"})
	if retryErr != nil || !result.Fresh {
		t.Fatalf("retry after rolled-back install: result=%+v err=%v", result, retryErr)
	}
}

func TestInstallerRejectsSymlinkedJournalDirectory(t *testing.T) {
	installer := testInstaller(t, &fakeRunner{}, &fakeVerifier{})
	if err := os.MkdirAll(filepath.Dir(installer.Paths.LogDir), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(t.TempDir(), installer.Paths.LogDir); err != nil {
		t.Fatal(err)
	}
	if _, err := installer.Install(context.Background(), validConfig(), InstallOptions{}); err == nil || !strings.Contains(err.Error(), "journal path is not a real directory") {
		t.Fatalf("symlinked journal result: %v", err)
	}
}

func TestInstallerRollsBackPartialDirectoryPreparation(t *testing.T) {
	installer := testInstaller(t, &fakeRunner{}, &fakeVerifier{})
	installer.Chown = func(string, int, int) error { return errors.New("synthetic chown failure") }
	if _, err := installer.Install(context.Background(), validConfig(), InstallOptions{}); err == nil {
		t.Fatal("expected preparation failure")
	}
	for _, path := range []string{installer.Paths.EtcDir, installer.Paths.OptDir, installer.Paths.DataDir, installer.Paths.BackupDir} {
		if _, statErr := os.Stat(path); !errors.Is(statErr, os.ErrNotExist) {
			t.Errorf("partial preparation retained %s: %v", path, statErr)
		}
	}
}

func TestInstallerDetectsModifiedOwnedFile(t *testing.T) {
	installer := testInstaller(t, &fakeRunner{}, &fakeVerifier{})
	if _, err := installer.Install(context.Background(), validConfig(), InstallOptions{}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(installer.Paths.Caddyfile, []byte("modified"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := installer.Install(context.Background(), validConfig(), InstallOptions{}); err == nil || !strings.Contains(err.Error(), "modified outside") {
		t.Fatalf("unexpected modified-file result: %v", err)
	}
}

func TestInstallerRejectsUnexpectedOwnedPath(t *testing.T) {
	installer := testInstaller(t, &fakeRunner{}, &fakeVerifier{})
	if _, err := installer.Install(context.Background(), validConfig(), InstallOptions{}); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(installer.Paths.ManifestPath)
	if err != nil {
		t.Fatal(err)
	}
	var manifest OwnershipManifest
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatal(err)
	}
	manifest.Files[0].Path = "/etc/passwd"
	if err := writeJSONAtomic(installer.Paths.ManifestPath, manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := installer.Install(context.Background(), validConfig(), InstallOptions{}); err == nil || !strings.Contains(err.Error(), "unexpected file metadata") {
		t.Fatalf("unexpected manifest result: %v", err)
	}
}

func TestPublicVerifierChecksIdentityCookieAndLogout(t *testing.T) {
	loggedOut := false
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/healthz":
			w.WriteHeader(http.StatusOK)
		case "/v1/capabilities":
			_ = json.NewEncoder(w).Encode(map[string]any{"product": "rctl", "component": "relay", "protocol": map[string]int{"major": 1, "minor": 0}})
		case "/device":
			conn, err := websocket.Accept(w, r, nil)
			if err == nil {
				defer conn.CloseNow()
				_, _, _ = conn.Read(r.Context())
			}
		case "/api/admin/login":
			http.SetCookie(w, &http.Cookie{Name: "rctl_session", Value: "session.secret", Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode})
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		case "/api/admin/logout":
			if cookie, err := r.Cookie("rctl_session"); err == nil && cookie.Value == "session.secret" {
				loggedOut = true
			}
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	if err := verifyPublicOnce(context.Background(), server.Client(), server.URL, strings.Repeat("a", 64)); err != nil {
		t.Fatal(err)
	}
	if !loggedOut {
		t.Fatal("verification session was not revoked")
	}
}

func TestPublicRouteVerifierAcceptsProtectedDeviceWebSocket(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/healthz":
			w.WriteHeader(http.StatusOK)
		case "/v1/capabilities":
			_ = json.NewEncoder(w).Encode(map[string]any{"product": "rctl", "component": "relay", "protocol": map[string]int{"major": 1}})
		case "/device":
			http.Error(w, "device authentication required", http.StatusUnauthorized)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	if err := verifyPublicRoutes(context.Background(), server.Client(), server.URL); err != nil {
		t.Fatal(err)
	}
}

func TestPublicVerifierProvesSessionPersistenceAcrossRestart(t *testing.T) {
	restarted := false
	loggedOut := false
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/admin/login":
			http.SetCookie(w, &http.Cookie{Name: "rctl_session", Value: "session.secret", Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode})
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		case "/api/admin/status":
			cookie, err := r.Cookie("rctl_session")
			if !restarted || err != nil || cookie.Value != "session.secret" {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		case "/api/admin/logout":
			loggedOut = true
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	verifier := HTTPSVerifier{Client: server.Client()}
	cfg := validConfig()
	cfg.PublicURL = server.URL
	err := verifier.VerifyPersistence(context.Background(), cfg, strings.Repeat("a", 64), func(context.Context) error {
		restarted = true
		return nil
	})
	if err != nil || !restarted || !loggedOut {
		t.Fatalf("err=%v restarted=%t loggedOut=%t", err, restarted, loggedOut)
	}
}

func TestPublicVerifierRevokesProbeSessionWhenRestartFails(t *testing.T) {
	loggedOut := false
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/admin/login":
			http.SetCookie(w, &http.Cookie{Name: "rctl_session", Value: "session.secret", Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode})
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		case "/api/admin/logout":
			loggedOut = true
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		}
	}))
	defer server.Close()
	verifier := HTTPSVerifier{Client: server.Client()}
	cfg := validConfig()
	cfg.PublicURL = server.URL
	err := verifier.VerifyPersistence(context.Background(), cfg, strings.Repeat("a", 64), func(context.Context) error {
		return errors.New("restart failed")
	})
	if err == nil || !loggedOut {
		t.Fatalf("err=%v loggedOut=%t", err, loggedOut)
	}
}
