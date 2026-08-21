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
	"testing"
	"time"

	"nhooyr.io/websocket"
)

type fakeRunner struct {
	calls  []string
	failAt int
}

func (r *fakeRunner) Run(_ context.Context, name string, args ...string) (string, error) {
	r.calls = append(r.calls, name+" "+strings.Join(args, " "))
	if r.failAt > 0 && len(r.calls) == r.failAt {
		return "synthetic failure", errors.New("exit 1")
	}
	if len(args) > 0 && args[len(args)-1] == "--services" {
		return "relay\ncaddy\ncoturn", nil
	}
	return "ok", nil
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
