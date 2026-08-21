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
	calls int
	err   error
}

func (v *fakeVerifier) Verify(context.Context, Config, string) error {
	v.calls++
	return v.err
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
	if !result.Fresh || len(result.AdminSecret) < 48 || verifier.calls != 2 {
		t.Fatalf("unexpected fresh result: %#v calls=%d", result, verifier.calls)
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
	if result.Fresh || result.AdminSecret != "" || verifier.calls != 3 {
		t.Fatalf("idempotent install leaked/regenerated credentials: %#v calls=%d", result, verifier.calls)
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

func TestPublicVerifierChecksIdentityCookieAndLogout(t *testing.T) {
	loggedOut := false
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/healthz":
			w.WriteHeader(http.StatusOK)
		case "/v1/capabilities":
			_ = json.NewEncoder(w).Encode(map[string]string{"product": "rctl", "component": "relay"})
		case "/api/admin/login":
			http.SetCookie(w, &http.Cookie{Name: "rctl_admin", Value: "session", Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode})
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		case "/api/admin/logout":
			if cookie, err := r.Cookie("rctl_admin"); err == nil && cookie.Value == "session" {
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
