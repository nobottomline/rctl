package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
	"tailscale.com/ipn/ipnstate"
)

// Upstream also accepts ambient credentials. This probe requires explicit
// enrollment so a shell environment cannot silently choose another identity.
func explicitEnrollmentEnvironment() error {
	for _, name := range []string{"TS_AUTHKEY", "TS_AUTH_KEY", "TS_CLIENT_SECRET", "TS_CLIENT_ID", "TS_ID_TOKEN", "TS_AUDIENCE", "TSNET_FORCE_LOGIN", "TS_CONTROL_URL"} {
		if os.Getenv(name) != "" {
			return errors.New("remove ambient Tailscale enrollment variables; use enroll or auth-key-file explicitly")
		}
	}
	return nil
}

func requireSavedIdentity(state string) error {
	fd, err := unix.Open(filepath.Join(state, "tailscaled.state"), unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return errors.New("no saved identity; run enroll or supply auth-key-file first")
	}
	f := os.NewFile(uintptr(fd), "identity")
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() == 0 {
		return errors.New("saved identity must be a non-empty private regular file")
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || int(stat.Uid) != os.Geteuid() {
		return errors.New("saved identity must belong to the current user")
	}
	// The contents are deliberately not parsed here: tsnet validates its state.
	return nil
}

type loginDocument struct {
	file *os.File
	path string
}

func newLoginDocument(state string) (*loginDocument, error) {
	f, err := os.CreateTemp(state, "login-*.md")
	if err != nil {
		return nil, errors.New("cannot create private login document")
	}
	return &loginDocument{file: f, path: f.Name()}, nil
}

func (d *loginDocument) Close() {
	_ = d.file.Close()
	_ = os.Remove(d.path)
}

func (d *loginDocument) Write(rawURL string) error {
	u, err := url.Parse(rawURL)
	if err != nil || len(rawURL) > 2048 || u.Scheme != "https" || u.Host != "login.tailscale.com" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || !strings.HasPrefix(u.Path, "/a/") {
		return errors.New("unexpected enrollment URL; no login link was published")
	}
	for _, c := range strings.TrimPrefix(u.Path, "/a/") {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return errors.New("invalid enrollment URL path")
		}
	}
	if u.Path == "/a/" || u.RawPath != "" {
		return errors.New("invalid enrollment URL path")
	}
	if err := d.file.Truncate(0); err != nil {
		return errors.New("cannot update private login document")
	}
	if _, err := d.file.Seek(0, io.SeekStart); err != nil {
		return errors.New("cannot update private login document")
	}
	if _, err := fmt.Fprintf(d.file, "# Tailscale Test Enrollment\n\n[Connect the test node](%s)\n\nApprove only the expected test hostname. This step does not expose rctl.\n", rawURL); err != nil {
		return errors.New("cannot write private login document")
	}
	return nil
}

func enrollBrowser(ctx context.Context, status func(context.Context) (*ipnstate.Status, error), login *loginDocument, out io.Writer) error {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	previousURL := ""
	for {
		check, cancel := context.WithTimeout(ctx, 5*time.Second)
		current, err := status(check)
		cancel()
		if err != nil || current == nil {
			return errors.New("cannot read enrollment status")
		}
		if current.BackendState == "Running" && len(current.TailscaleIPs) != 0 {
			return nil
		}
		if current.AuthURL != "" && current.AuthURL != previousURL {
			if err := login.Write(current.AuthURL); err != nil {
				return err
			}
			previousURL = current.AuthURL
			fmt.Fprintln(out, "Open the private login document:", login.path)
		}
		select {
		case <-ctx.Done():
			return errors.New("enrollment canceled or timed out; rerun enroll to try again")
		case <-ticker.C:
		}
	}
}
