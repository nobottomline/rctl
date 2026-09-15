package setup

import (
	"context"
	"crypto/subtle"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"github.com/nobottomline/rctl/relay/internal/releasefeed"
)

const (
	HostAgentBinary    = "/usr/local/libexec/rctl-update-agent"
	HostAgentState     = "/var/lib/rctl-update"
	HostAgentSocketDir = "/run/rctl-update"
	HostAgentSocket    = HostAgentSocketDir + "/agent.sock"
	hostAgentUnitPath  = "/etc/systemd/system/rctl-update-agent.service"
)

func hostUpdateAuthorization(next http.Handler, secret func() (string, error)) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		expected, err := secret()
		if err != nil || len(expected) < 24 {
			http.Error(w, "update authorization unavailable", http.StatusServiceUnavailable)
			return
		}
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+expected)) != 1 {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

const hostAgentUnit = `# Managed by rctl-setup; host-update protocol 1.
[Unit]
Description=rctl verified update supervisor
After=network-online.target docker.service
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStart=/usr/local/libexec/rctl-update-agent updates serve
Restart=always
RestartSec=10
TimeoutStopSec=1300
KillMode=mixed
RuntimeDirectory=rctl-update
RuntimeDirectoryMode=0755
UMask=0077
NoNewPrivileges=true
# Docker must see the private temporary candidate paths used by setup validation.
PrivateTmp=false
ProtectHome=true
ProtectSystem=full
# Keep /var/lib/rctl off the mount allowlist: rollback atomically renames it.
# ProtectSystem=full already leaves /var and /opt writable.
ReadWritePaths=/etc/rctl /usr/local/libexec /usr/local/bin
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
`

// EnableHostUpdates is run by the verified bootstrap after a managed install or
// upgrade commits. Existing unmanaged services and locally modified units fail
// closed. It never changes a relay deployment or its credentials.
func EnableHostUpdates(ctx context.Context, executable, catalogURL string) error {
	if runtime.GOOS != "linux" || os.Geteuid() != 0 {
		return errors.New("host updates require root on Linux with systemd")
	}
	if catalogURL != "" && !releasefeed.ValidCatalogURL(catalogURL) {
		return errors.New("catalog URL must be a release catalog in the official repository")
	}
	owned, err := InstallationOwned(DefaultPaths())
	if err != nil || !owned {
		return errors.New("host updates require a wizard-managed installation")
	}
	if raw, err := readRegularFile(hostAgentUnitPath, 64<<10, 0); err == nil {
		if string(raw) != hostAgentUnit {
			return errors.New("host update unit has local changes; refusing to replace it")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	} else {
		if _, err := os.Lstat(HostAgentBinary); !errors.Is(err, os.ErrNotExist) {
			return errors.New("unmanaged host updater binary already exists")
		}
	}
	for _, dir := range []string{HostAgentState, filepath.Dir(HostAgentBinary), HostAgentSocketDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		info, err := os.Lstat(dir)
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0o022 != 0 {
			return errors.New("unsafe host update directory")
		}
		if stat, ok := info.Sys().(*syscall.Stat_t); !ok || stat.Uid != 0 {
			return errors.New("host updater directory must be owned by root")
		}
	}
	if err := os.Chmod(HostAgentState, 0o700); err != nil {
		return err
	}
	if catalogURL != "" {
		if err := writeJSONAtomic(filepath.Join(HostAgentState, "source.json"), map[string]string{"url": catalogURL}, 0o600); err != nil {
			return err
		}
	}
	raw, err := readRegularFile(executable, 512<<20, 0)
	if err != nil {
		return err
	}
	if err := writeFileAtomic(HostAgentBinary, raw, 0o755); err != nil {
		return err
	}
	if err := writeFileAtomic(hostAgentUnitPath, []byte(hostAgentUnit), 0o644); err != nil {
		return err
	}
	for _, args := range [][]string{{"daemon-reload"}, {"enable", "--now", "rctl-update-agent.service"}, {"restart", "rctl-update-agent.service"}} {
		if _, err := (OSRunner{}).Run(ctx, "systemctl", args...); err != nil {
			return errors.New("could not activate host update service")
		}
	}
	return nil
}

func disableHostUpdates(ctx context.Context, paths Paths, runner Runner) error {
	// Qualification tests and relocated installations must never touch host units.
	if paths.ManifestPath != DefaultPaths().ManifestPath {
		return nil
	}
	raw, err := readRegularFile(hostAgentUnitPath, 64<<10, 0)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !strings.HasPrefix(string(raw), "# Managed by rctl-setup; host-update protocol 1.\n") {
		return errors.New("unmanaged update unit")
	}
	_, err = runner.Run(ctx, "systemctl", "disable", "--now", "rctl-update-agent.service")
	return err
}
