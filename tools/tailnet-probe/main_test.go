package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/tailcfg"
)

func TestWhoIsIdentity(t *testing.T) {
	identity := &apitype.WhoIsResponse{Node: &tailcfg.Node{}, UserProfile: &tailcfg.UserProfile{ID: 123}}
	if !allowedIdentity(identity, "123") {
		t.Fatal("matching untagged owner denied")
	}
	if allowedIdentity(identity, "456") {
		t.Fatal("different owner accepted")
	}
	if allowedIdentity(identity, "userid:123") {
		t.Fatal("display string accepted instead of numeric ID")
	}
	identity.Node.Expired = true
	if allowedIdentity(identity, "123") {
		t.Fatal("expired node accepted")
	}
	identity.Node.Expired = false
	identity.Node.KeyExpiry = time.Now().Add(-time.Minute)
	if allowedIdentity(identity, "123") {
		t.Fatal("expired key accepted")
	}
	identity.Node.KeyExpiry = time.Now().Add(time.Minute)
	if !allowedIdentity(identity, "123") {
		t.Fatal("valid expiring key denied")
	}
	identity.Node.Tags = []string{"tag:server"}
	if allowedIdentity(identity, "123") {
		t.Fatal("tag-owned peer accepted")
	}
	for _, missing := range []*apitype.WhoIsResponse{nil, {}, {Node: &tailcfg.Node{}}, {UserProfile: &tailcfg.UserProfile{ID: 123}}} {
		if allowedIdentity(missing, "123") {
			t.Fatal("incomplete identity accepted")
		}
	}
}

func TestCheckDoesNotInitializeState(t *testing.T) {
	state := filepath.Join(t.TempDir(), "unused")
	var out bytes.Buffer
	if err := run([]string{"--check", "--state-dir", state}, &out); err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := json.Unmarshal(out.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result["network_started"] != false || result["rctl_access"] != false {
		t.Fatal(result)
	}
	if _, err := os.Stat(state); !os.IsNotExist(err) {
		t.Fatalf("state unexpectedly initialized: %v", err)
	}
}

func TestCLIControlTransport(t *testing.T) {
	if os.Getenv("RCTL_PROBE_TEST_ENTRYPOINT") == "1" {
		os.Args = []string{"tailnet-probe", "--check"}
		main()
		os.Exit(0)
	}
	command := exec.Command(os.Args[0], "-test.run=^TestCLIControlTransport$")
	command.Env = append(os.Environ(), "RCTL_PROBE_TEST_ENTRYPOINT=1", "TS_FORCE_NOISE_443=false")
	output, err := command.Output()
	if err != nil {
		t.Fatal("entrypoint check failed", err)
	}
	var result map[string]any
	if err := json.Unmarshal(output, &result); err != nil {
		t.Fatal(err)
	}
	if result["control_https_only"] != true || result["network_started"] != false || result["rctl_access"] != false {
		t.Fatal("entrypoint did not select HTTPS-only control without starting the network", result)
	}
}

func TestIdentityValidation(t *testing.T) {
	for _, tc := range []struct {
		host, user string
		valid      bool
	}{
		{"rctl-test", "123", true}, {"", "123", false}, {"private.example", "123", false},
		{"Host", "123", false}, {"-host", "123", false}, {"host-", "123", false},
		{strings.Repeat("x", 64), "123", false}, {"host", "", false}, {"host", "*", false},
		{"host", "0", false}, {"host", "0123", false}, {"host", strings.Repeat("9", 30), false},
	} {
		if err := validateIdentity(tc.host, tc.user); (err == nil) != tc.valid {
			t.Errorf("%q/%q: %v", tc.host, tc.user, err)
		}
	}
}

func TestPrivateFiles(t *testing.T) {
	dir := t.TempDir()
	state := filepath.Join(dir, "state")
	if err := prepareState(state); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(state, 0755); err != nil {
		t.Fatal(err)
	}
	if err := prepareState(state); err == nil {
		t.Fatal("public state accepted")
	}
	if err := prepareState("relative"); err == nil {
		t.Fatal("relative state accepted")
	}
	stateLink := filepath.Join(dir, "state-link")
	if err := os.Symlink(state, stateLink); err != nil {
		t.Fatal(err)
	}
	if err := prepareState(stateLink); err == nil {
		t.Fatal("symlink state accepted")
	}
	if err := prepareState(stateLink + "/."); err == nil {
		t.Fatal("symlink state with directory suffix accepted")
	}
	key := filepath.Join(dir, "key")
	// Synthetic, non-functional token; never use live enrollment data in tests.
	const fixture = "tskey-auth-synthetic-test-not-a-credential"
	if err := os.WriteFile(key, []byte(fixture), 0600); err != nil {
		t.Fatal(err)
	}
	if got, err := readKey(key); err != nil || got != fixture {
		t.Fatal("private key rejected", err)
	}
	link := filepath.Join(dir, "key-link")
	if err := os.Symlink(key, link); err != nil {
		t.Fatal(err)
	}
	if _, err := readKey(link); err == nil {
		t.Fatal("symlink accepted")
	}
	if err := os.Chmod(key, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := readKey(key); err == nil {
		t.Fatal("public key accepted")
	}
	if err := os.Chmod(key, 0600); err != nil {
		t.Fatal(err)
	}
	for _, value := range []string{"", "invalid", fixture + "\nother", strings.Repeat("a", 513)} {
		if err := os.WriteFile(key, []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := readKey(key); err == nil {
			t.Fatal("invalid key accepted")
		}
	}
}

func TestDiagnosticBoundary(t *testing.T) {
	for _, tc := range []struct {
		method, path string
		allowed      bool
		status       int
	}{
		{"GET", "/healthz", true, 200}, {"GET", "/healthz", false, 403},
		{"GET", "/v1/info", true, 404}, {"GET", "/healthz?secret=x", true, 404},
		{"POST", "/healthz", true, 405}, {"GET", "/ws/signal", true, 404},
	} {
		t.Run(tc.method+tc.path+strconv.Itoa(tc.status), func(t *testing.T) {
			h := diagnosticHandler(func(ctx context.Context, addr string) bool {
				if _, ok := ctx.Deadline(); !ok {
					t.Error("missing authorization deadline")
				}
				if addr != "100.64.0.1:1234" {
					t.Error("unexpected identity address")
				}
				return tc.allowed
			})
			r := httptest.NewRequest(tc.method, tc.path, nil)
			r.RemoteAddr = "100.64.0.1:1234"
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.status {
				t.Fatal(w.Code, w.Body.String())
			}
			if w.Header().Get("Cache-Control") != "no-store" {
				t.Fatal("missing cache restriction")
			}
		})
	}
}
