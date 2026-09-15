package setup

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nobottomline/rctl/relay/internal/releasefeed"
)

func updateFixture(t *testing.T) (*HostUpdater, releasefeed.Catalog) {
	t.Helper()
	u, err := NewHostUpdater(PathsUnder(t.TempDir()), t.TempDir(), "0.4.0")
	if err != nil {
		t.Fatal(err)
	}
	u.ctx = context.Background()
	u.state.Status.Installed = "0.4.0"
	u.installed = func() (string, error) { return "0.4.0", nil }
	u.recover = func(context.Context) error { return nil }
	c := releasefeed.Catalog{Purpose: releasefeed.Purpose, Channel: "stable", Version: "0.5.0", IssuedAt: time.Now().Unix(), ExpiresAt: time.Now().Add(time.Hour).Unix(), AgentProtocol: 1, Artifacts: map[string]releasefeed.Artifact{}}
	for _, name := range releasefeed.Names(c.Version) {
		c.Artifacts[name] = releasefeed.Artifact{SHA256: strings.Repeat("a", 64), Size: 42}
	}
	u.check = func(context.Context) (releasefeed.Catalog, error) { return c, nil }
	return u, c
}

func checked(t *testing.T, u *HostUpdater) {
	t.Helper()
	if err := u.Check(); err != nil {
		t.Fatal(err)
	}
	u.Wait()
}

func TestHostUpdaterVerifiedSelectionAndSerialization(t *testing.T) {
	u, _ := updateFixture(t)
	if err := u.Install("0.5.0"); err == nil {
		t.Fatal("installed without verified catalog")
	}
	checked(t, u)
	if !u.Status().Available {
		t.Fatal(u.Status())
	}
	if err := u.Install("9.0.0"); err == nil {
		t.Fatal("accepted browser-selected arbitrary version")
	}
	entered, release := make(chan struct{}), make(chan struct{})
	u.apply = func(context.Context, releasefeed.Catalog) error { close(entered); <-release; return nil }
	u.installed = func() (string, error) { return "0.5.0", nil }
	if err := u.Install("0.5.0"); err != nil {
		t.Fatal(err)
	}
	<-entered
	if u.Install("0.5.0") == nil || u.Check() == nil || u.Policy(HostUpdatePolicy{}) == nil {
		t.Fatal("overlapping operation admitted")
	}
	close(release)
	u.Wait()
	s := u.Status()
	if s.Phase != "succeeded" || s.Available || s.Installed != "0.5.0" {
		t.Fatal(s)
	}
	if s.Job == nil || s.Job.Phase != "succeeded" || s.Job.CompletedAt == 0 {
		t.Fatal("successful job was not finalized", s)
	}
	if u.Install("0.5.0") == nil {
		t.Fatal("accepted same version")
	}
	select {
	case <-u.Restart():
	default:
		t.Fatal("supervisor activation did not request restart")
	}
}

func TestHostServicePreservesRollbackDirectoryRenames(t *testing.T) {
	// ReadWritePaths introduces mount points. applyBackup must rename DataDir,
	// which fails with EBUSY if the service pins that directory as a mount.
	for _, line := range strings.Split(hostAgentUnit, "\n") {
		if !strings.HasPrefix(line, "ReadWritePaths=") {
			continue
		}
		for _, path := range strings.Fields(strings.TrimPrefix(line, "ReadWritePaths=")) {
			if path == DefaultPaths().DataDir {
				t.Fatal("rollback data directory must not be a service mount point")
			}
		}
	}
}

func TestHostUpdaterRejectsReplayExpiryAndFetchFailure(t *testing.T) {
	for _, kind := range []string{"replay", "expired", "network"} {
		t.Run(kind, func(t *testing.T) {
			u, c := updateFixture(t)
			checked(t, u)
			u.state.Status.CheckedAt = 0
			switch kind {
			case "replay":
				u.state.Highest = "0.6.0"
			case "expired":
				c.ExpiresAt = time.Now().Add(-time.Hour).Unix()
			}
			u.check = func(context.Context) (releasefeed.Catalog, error) {
				if kind == "network" {
					return c, errors.New("private network error")
				}
				return c, nil
			}
			checked(t, u)
			if u.Status().Available || u.Install("0.5.0") == nil || strings.Contains(u.Status().Error, "private") {
				t.Fatal(u.Status())
			}
		})
	}
}

func TestHostUpdaterPolicyPersistsAndFailureDoesNotLoop(t *testing.T) {
	u, _ := updateFixture(t)
	checked(t, u)
	if u.Status().Policy.Automatic {
		t.Fatal("automatic installs must be opt-in")
	}
	if u.Policy(HostUpdatePolicy{HourUTC: 24}) == nil {
		t.Fatal("invalid hour")
	}
	p := HostUpdatePolicy{Automatic: true, HourUTC: time.Now().UTC().Hour()}
	if err := u.Policy(p); err != nil {
		t.Fatal(err)
	}
	var attempts, recoveries atomic.Int32
	u.apply = func(context.Context, releasefeed.Catalog) error {
		attempts.Add(1)
		return errors.New("secret command output")
	}
	u.recover = func(context.Context) error { recoveries.Add(1); return nil }
	u.tick()
	u.Wait()
	u.tick()
	u.Wait()
	if attempts.Load() != 1 || recoveries.Load() != 1 || u.Status().Phase != "failed" || strings.Contains(u.Status().Error, "secret") {
		t.Fatal(u.Status(), attempts.Load(), recoveries.Load())
	}
	loaded, err := NewHostUpdater(u.paths, u.stateDir, u.version)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.state.Status.Policy != p || loaded.state.Attempted != "0.5.0" || loaded.state.Highest != "0.5.0" {
		t.Fatal(loaded.state)
	}
	u.state.Status.CheckedAt = 0
	checked(t, u)
	if u.Status().Job == nil || u.Status().Job.Phase != "failed" {
		t.Fatal("release check erased the last job", u.Status())
	}
}

func TestHostUpdaterInterruptedRecoveryFailsClosed(t *testing.T) {
	u, _ := updateFixture(t)
	u.state.Status.Phase = "installing"
	u.recover = func(context.Context) error { return errors.New("recovery failed") }
	ctx, cancel := context.WithCancel(context.Background())
	if err := u.Start(ctx); err != nil {
		cancel()
		t.Fatal(err)
	}
	cancel()
	u.Wait()
	if u.Status().Phase != "recovery_required" || u.Check() == nil || u.Install("0.5.0") == nil {
		t.Fatal(u.Status())
	}
}

func TestHostUpdaterAPIRejectsCommandInjectionAndOversizedBody(t *testing.T) {
	u, _ := updateFixture(t)
	checked(t, u)
	for _, body := range []string{`{"version":"0.5.0","command":"sh"}`, `{"version":"0.5.0"} {}`, strings.Repeat("x", 1025), `{"version":"file:///tmp/evil"}`} {
		req := httptest.NewRequest(http.MethodPost, "/install", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		u.Handler().ServeHTTP(w, req)
		if w.Code != http.StatusConflict {
			t.Fatal(body, w.Code)
		}
	}
	w := httptest.NewRecorder()
	u.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/shell", nil))
	if w.Code != http.StatusNotFound {
		t.Fatal(w.Code)
	}
}

func TestHostUpdateCredentialRequiredEvenForAllowedPeer(t *testing.T) {
	expected := "test-host-admin-secret-not-production"
	h := hostUpdateAuthorization(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }), func() (string, error) { return expected, nil })
	for _, token := range []string{"", "Bearer wrong", "Bearer " + expected} {
		r := httptest.NewRequest("GET", "/status", nil)
		r.Header.Set("Authorization", token)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		want := 403
		if token == "Bearer "+expected {
			want = 200
		}
		if w.Code != want {
			t.Fatal(w.Code)
		}
	}
	r := httptest.NewRequest("GET", "/status", nil)
	r.Header.Set("Authorization", "Bearer "+expected)
	expected = "rotated-test-host-admin-secret"
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("old credential survived rotation")
	}
}

func TestHostUpdaterStorageFailurePreventsInstall(t *testing.T) {
	u, _ := updateFixture(t)
	checked(t, u)
	if err := os.Mkdir(filepath.Join(u.stateDir, "state.json.new"), 0o700); err != nil {
		t.Fatal(err)
	}
	// Replace only our disposable state directory with an ordinary file.
	if err := os.RemoveAll(u.stateDir); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(u.stateDir, []byte("unavailable"), 0o600); err != nil {
		t.Fatal(err)
	}
	u.apply = func(context.Context, releasefeed.Catalog) error {
		t.Error("apply called without durable job")
		return nil
	}
	if u.Install("0.5.0") == nil {
		t.Fatal("accepted non-durable update")
	}
	u.Wait()
}

type hostRoundTrip func(*http.Request) (*http.Response, error)

func (f hostRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type hostRunnerFunc func(context.Context, string, ...string) (string, error)

func (f hostRunnerFunc) Run(ctx context.Context, name string, args ...string) (string, error) {
	return f(ctx, name, args...)
}

func TestHostReleaseVerifiesBeforeExecutingAndActivating(t *testing.T) {
	for _, scenario := range []string{"success", "corrupt", "wrong-version", "upgrade-failure"} {
		t.Run(scenario, func(t *testing.T) {
			installer, _, _, _ := createUpgradeFixture(t)
			u, c := updateFixture(t)
			u.paths = installer.Paths
			c.Version = "1.3.0"
			c.Artifacts = map[string]releasefeed.Artifact{}
			artifact, _ := releasefeed.Inspect(strings.NewReader("verified setup candidate"))
			for _, name := range releasefeed.Names(c.Version) {
				c.Artifacts[name] = artifact
			}
			u.client = &http.Client{Transport: hostRoundTrip(func(r *http.Request) (*http.Response, error) {
				body := "verified setup candidate"
				if scenario == "corrupt" {
					body = "untrusted replacement"
				}
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
			})}
			calls := 0
			activated := false
			u.runner = hostRunnerFunc(func(ctx context.Context, name string, args ...string) (string, error) {
				calls++
				if !strings.HasPrefix(name, u.stateDir+"/stage-") {
					t.Fatal("executing outside private stage")
				}
				if calls == 1 {
					if strings.Join(args, " ") != "version" {
						t.Fatal(args)
					}
					if scenario == "wrong-version" {
						return "rctl-setup 9.0.0 (test)", nil
					}
					return "rctl-setup 1.3.0 (test)", nil
				}
				if strings.Join(args, " ") != "upgrade --yes" {
					t.Fatal(args)
				}
				if scenario == "upgrade-failure" {
					return "untrusted command output", errors.New("failed")
				}
				return "", nil
			})
			u.installed = func() (string, error) { return "1.3.0", nil }
			u.activate = func(path string) error { activated = true; return nil }
			err := u.applyRelease(context.Background(), c)
			if scenario == "success" {
				if err != nil || !activated || calls != 2 {
					t.Fatal(err, activated, calls)
				}
			} else {
				if err == nil || activated {
					t.Fatal(err, activated)
				}
				if scenario == "corrupt" && calls != 0 {
					t.Fatal("unverified candidate executed")
				}
			}
			stages, _ := filepath.Glob(filepath.Join(u.stateDir, "stage-*"))
			if len(stages) != 0 {
				t.Fatal("candidate stage leaked", stages)
			}
		})
	}
}
