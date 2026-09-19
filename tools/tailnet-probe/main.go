// tailnet-probe qualifies the optional transport; device proxying is opt-in.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/tsnet"
)

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "tailnet-probe:", err)
		os.Exit(1)
	}
}

func run(args []string, out io.Writer) error {
	flags := flag.NewFlagSet("tailnet-probe", flag.ContinueOnError)
	check := flags.Bool("check", false, "check the runtime without registering a node or starting listeners")
	state := flags.String("state-dir", "", "private directory for this probe's Tailscale identity")
	hostname := flags.String("hostname", "", "non-personal DNS label for this probe")
	userID := flags.String("allow-user-id", "", "Tailscale user ID allowed to use this probe (full device control with --rctl)")
	keyFile := flags.String("auth-key-file", "", "private file containing a one-off, non-ephemeral auth key")
	rctl := flags.Bool("rctl", false, "experimental HTTPS gateway to this device's LAN-enabled rctl; not a release feature")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	if *check {
		return json.NewEncoder(out).Encode(map[string]any{
			"runtime": runtime.Version(), "os": runtime.GOOS, "arch": runtime.GOARCH,
			"tailscale": "1.102.4", "network_started": false, "rctl_access": false,
		})
	}
	if err := validateIdentity(*hostname, *userID); err != nil {
		return err
	}
	if err := prepareState(*state); err != nil {
		return err
	}
	key, err := readKey(*keyFile)
	if err != nil {
		return err
	}
	if key == "" {
		return errors.New("an auth-key-file is required for this diagnostic build")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	server := &tsnet.Server{
		Dir: *state, Hostname: *hostname, AuthKey: key, Ephemeral: false,
		// Upstream diagnostics can contain auth URLs and personal identifiers.
		Logf: func(string, ...any) {}, UserLogf: func(string, ...any) {},
	}
	defer server.Close()
	startup, stopStartup := context.WithTimeout(ctx, 90*time.Second)
	status, err := server.Up(startup)
	stopStartup()
	if err != nil {
		return errors.New("Tailscale connection failed; check enrollment, approval and connectivity")
	}
	client, err := server.LocalClient()
	if err != nil {
		return errors.New("Tailscale identity service is unavailable")
	}
	listener, err := server.ListenTLS("tcp", ":443")
	if err != nil {
		return errors.New("HTTPS listener unavailable; enable MagicDNS and HTTPS certificates in Tailscale")
	}
	defer listener.Close()
	authorize := func(ctx context.Context, addr string) bool {
		identity, err := client.WhoIs(ctx, addr)
		return err == nil && allowedIdentity(identity, *userID)
	}
	var handler http.Handler = diagnosticHandler(authorize)
	var deviceGateway *gateway
	if *rctl {
		if status.Self == nil {
			return errors.New("gateway identity is unavailable")
		}
		deviceGateway, err = newGateway(strings.TrimSuffix(status.Self.DNSName, "."), authorize)
		if err != nil {
			return err
		}
		defer deviceGateway.Close()
		handler = deviceGateway
	}
	httpServer := &http.Server{
		Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192,
		ErrorLog: log.New(io.Discard, "", 0),
	}
	if deviceGateway != nil {
		httpServer.ReadTimeout = 60 * time.Second
		// Downloads stream with backpressure rather than a whole-file buffer.
		httpServer.WriteTimeout = 0
	}
	stopped := make(chan struct{})
	defer close(stopped)
	go func() {
		select {
		case <-ctx.Done():
			if deviceGateway != nil {
				deviceGateway.Close()
			}
			_ = httpServer.Close()
		case <-stopped:
		}
	}()
	if deviceGateway == nil {
		fmt.Fprintln(out, "Private HTTPS probe ready; only GET /healthz is available. No rctl access is exposed.")
	} else {
		fmt.Fprintln(out, "Experimental private HTTPS gateway ready; LAN policy and permitted identity are required.")
	}
	if err := httpServer.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return errors.New("diagnostic HTTPS server stopped unexpectedly")
	}
	return nil
}

func allowedIdentity(identity *apitype.WhoIsResponse, userID string) bool {
	return identity != nil && identity.UserProfile != nil && identity.Node != nil &&
		!identity.Node.Expired && (identity.Node.KeyExpiry.IsZero() || identity.Node.KeyExpiry.After(time.Now())) &&
		len(identity.Node.Tags) == 0 && identity.UserProfile.ID > 0 &&
		strconv.FormatInt(int64(identity.UserProfile.ID), 10) == userID
}

func diagnosticHandler(authorize func(context.Context, string) bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		if !authorize(ctx, r.RemoteAddr) {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", "GET")
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if r.URL.Path != "/healthz" || r.URL.RawQuery != "" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, "{\"ok\":true,\"rctl_access\":false}\n")
	})
}

func validateIdentity(hostname, userID string) error {
	if len(hostname) < 1 || len(hostname) > 63 || strings.HasPrefix(hostname, "-") || strings.HasSuffix(hostname, "-") {
		return errors.New("hostname must be a DNS label of 1 to 63 characters")
	}
	for _, c := range hostname {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return errors.New("hostname must contain lowercase ASCII letters, digits or hyphens")
		}
	}
	if userID == "" {
		return errors.New("allow-user-id is required; no default allow-all policy exists")
	}
	for _, c := range userID {
		if c < '0' || c > '9' {
			return errors.New("allow-user-id must be a numeric Tailscale user ID")
		}
	}
	if id, err := strconv.ParseInt(userID, 10, 64); err != nil || id <= 0 || strconv.FormatInt(id, 10) != userID {
		return errors.New("allow-user-id must be a canonical positive numeric ID")
	}
	return nil
}

func prepareState(path string) error {
	path = filepath.Clean(path)
	if !filepath.IsAbs(path) || filepath.Clean(path) == "/" {
		return errors.New("state-dir must be a private absolute directory")
	}
	if err := os.MkdirAll(path, 0700); err != nil {
		return errors.New("cannot create state directory")
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return errors.New("state directory must not be a symlink or accessible to other users")
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || int(stat.Uid) != os.Geteuid() {
		return errors.New("state directory must belong to the current user")
	}
	return nil
}

func readKey(path string) (string, error) {
	if path == "" {
		return "", nil
	}
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return "", errors.New("cannot open private auth key file")
	}
	f := os.NewFile(uintptr(fd), "auth-key")
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 512 {
		return "", errors.New("auth key must be in a private regular file, at most 512 bytes")
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || int(stat.Uid) != os.Geteuid() {
		return "", errors.New("auth key file must belong to the current user")
	}
	data, err := io.ReadAll(io.LimitReader(f, 513))
	if err != nil {
		return "", errors.New("cannot read auth key file")
	}
	if len(data) > 512 {
		return "", errors.New("auth key exceeds 512 bytes")
	}
	key := strings.TrimSpace(string(data))
	if !strings.HasPrefix(key, "tskey-auth-") || len(key) < 24 || strings.ContainsAny(key, "\r\n\t ") {
		return "", errors.New("invalid auth key format")
	}
	return key, nil
}
