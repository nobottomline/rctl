package main

import (
	"bytes"
	"context"
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"tailscale.com/ipn/ipnstate"
)

func TestLoginDocument(t *testing.T) {
	doc, err := newLoginDocument(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer doc.Close()
	info, err := os.Stat(doc.path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("login document is not private", err)
	}
	const fixture = "https://login.tailscale.com/a/synthetic-not-a-login"
	if err := doc.Write(fixture); err != nil {
		t.Fatal(err)
	}
	for _, value := range []string{
		"http://login.tailscale.com/a/test", "https://other.invalid/a/test",
		"https://login.tailscale.com.attacker.invalid/a/test", "https://login.tailscale.com:443/a/test",
		"https://user@login.tailscale.com/a/test", "https://login.tailscale.com/a/",
		"https://login.tailscale.com/a/test?secret=test", "https://login.tailscale.com/a/test#fragment",
		"https://login.tailscale.com/a/test%29", "https://login.tailscale.com/a/test/extra",
	} {
		if err := doc.Write(value); err == nil {
			t.Fatalf("invalid login URL accepted: %q", value)
		}
	}
	data, err := os.ReadFile(doc.path)
	if err != nil || !strings.Contains(string(data), fixture) {
		t.Fatal("rejected input replaced valid link", err)
	}
	doc.Close()
	if _, err := os.Stat(doc.path); !os.IsNotExist(err) {
		t.Fatal("login document survived cleanup", err)
	}
}

func TestEnrollmentDoesNotLogLoginURL(t *testing.T) {
	doc, err := newLoginDocument(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer doc.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var out bytes.Buffer
	err = enrollBrowser(ctx, func(ctx context.Context) (*ipnstate.Status, error) {
		if _, ok := ctx.Deadline(); !ok {
			t.Error("unbounded status request")
		}
		cancel()
		return &ipnstate.Status{AuthURL: "https://login.tailscale.com/a/synthetic-not-a-login"}, nil
	}, doc, &out)
	if err == nil || strings.Contains(out.String(), "https://") || strings.Contains(out.String(), "synthetic-not-a-login") || !strings.Contains(out.String(), doc.path) {
		t.Fatal("cancellation or log redaction failed", err)
	}
}

func TestEnrollmentStatus(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status *ipnstate.Status
		err    error
		ok     bool
	}{
		{"connected", &ipnstate.Status{BackendState: "Running", TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.1")}}, nil, true},
		{"no-ip", &ipnstate.Status{BackendState: "Running"}, nil, false},
		{"nil", nil, nil, false},
		{"error", nil, errors.New("private upstream detail"), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			doc, err := newLoginDocument(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer doc.Close()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var out bytes.Buffer
			err = enrollBrowser(ctx, func(context.Context) (*ipnstate.Status, error) {
				cancel()
				return tc.status, tc.err
			}, doc, &out)
			if (err == nil) != tc.ok || err != nil && strings.Contains(err.Error(), "private upstream detail") {
				t.Fatal(err)
			}
		})
	}
}

func TestSavedIdentity(t *testing.T) {
	dir := t.TempDir()
	if err := requireSavedIdentity(dir); err == nil {
		t.Fatal("missing identity accepted")
	}
	path := filepath.Join(dir, "tailscaled.state")
	for _, tc := range []struct {
		data string
		mode os.FileMode
		ok   bool
	}{
		{"synthetic state", 0600, true}, {"synthetic state", 0644, false}, {"", 0600, false},
	} {
		if err := os.WriteFile(path, []byte(tc.data), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, tc.mode); err != nil {
			t.Fatal(err)
		}
		if err := requireSavedIdentity(dir); (err == nil) != tc.ok {
			t.Fatal("incorrect identity file validation", err)
		}
	}
	other := t.TempDir()
	if err := os.Symlink(path, filepath.Join(other, "tailscaled.state")); err != nil {
		t.Fatal(err)
	}
	if err := requireSavedIdentity(other); err == nil {
		t.Fatal("symlink identity accepted")
	}
}

func TestEnrollmentOptions(t *testing.T) {
	for _, args := range [][]string{
		{"--enroll", "--rctl"}, {"--enroll", "--auth-key-file", "/unused"},
	} {
		var out bytes.Buffer
		if err := run(append(args, "--hostname", "test", "--allow-user-id", "1"), &out); err == nil {
			t.Fatal("conflicting enrollment options accepted")
		}
	}
	for _, name := range []string{"TS_AUTHKEY", "TS_AUTH_KEY", "TS_CLIENT_SECRET", "TS_CLIENT_ID", "TS_ID_TOKEN", "TS_AUDIENCE", "TSNET_FORCE_LOGIN", "TS_CONTROL_URL"} {
		t.Run(name, func(t *testing.T) {
			t.Setenv(name, "synthetic")
			if err := explicitEnrollmentEnvironment(); err == nil || strings.Contains(err.Error(), "synthetic") {
				t.Fatal("ambient identity was not rejected safely", err)
			}
		})
	}
}
