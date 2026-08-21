package setup

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/nobottomline/rctl/relay/internal/deb"
	"nhooyr.io/websocket"
)

const ownershipSchema = 1

type OwnedFile struct {
	Path   string `json:"path"`
	Mode   uint32 `json:"mode"`
	SHA256 string `json:"sha256"`
	Secret bool   `json:"secret,omitempty"`
}

type OwnershipManifest struct {
	Schema    int         `json:"schema"`
	Product   string      `json:"product"`
	Version   string      `json:"version"`
	CreatedAt int64       `json:"created_at"`
	UpdatedAt int64       `json:"updated_at"`
	Config    Config      `json:"config"`
	Files     []OwnedFile `json:"files"`
}

type Journal struct {
	Schema    int    `json:"schema"`
	Operation string `json:"operation"`
	Status    string `json:"status"`
	Stage     string `json:"stage"`
	StartedAt int64  `json:"started_at"`
	UpdatedAt int64  `json:"updated_at"`
	Error     string `json:"error,omitempty"`
}

type Runner interface {
	Run(ctx context.Context, name string, args ...string) (string, error)
}

type PublicVerifier interface {
	Verify(ctx context.Context, cfg Config, adminSecret string) error
	VerifyPersistence(ctx context.Context, cfg Config, adminSecret string, restart func(context.Context) error) error
}

type RouteVerifier interface {
	VerifyRoutes(ctx context.Context, cfg Config) error
}

type Chowner func(path string, uid, gid int) error

const (
	relayRuntimeUID  = 65532
	relayRuntimeGID  = 65532
	coturnRuntimeUID = 65534
	coturnRuntimeGID = 65533
)

type Installer struct {
	Paths    Paths
	Runner   Runner
	Verifier PublicVerifier
	Random   io.Reader
	Now      func() time.Time
	Chown    Chowner
}

type InstallOptions struct {
	DryRun              bool
	Version             string
	PublicPackageSource string
}

type InstallResult struct {
	Fresh       bool
	DryRun      bool
	AdminSecret string
	Files       []string
}

type OSRunner struct{}

func InstallationOwned(paths Paths) (bool, error) {
	if paths.ManifestPath == "" {
		paths = DefaultPaths()
	}
	manifest, err := loadManifest(paths.ManifestPath)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if err := validateOwnershipManifest(manifest, paths); err != nil {
		return false, err
	}
	return true, nil
}

func (OSRunner) Run(ctx context.Context, name string, args ...string) (string, error) {
	path, err := exec.LookPath(name)
	if err != nil {
		return "", err
	}
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.Env = []string{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C", "LC_ALL=C"}
	var output limitedBuffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	err = cmd.Run()
	return strings.TrimSpace(output.String()), err
}

type limitedBuffer struct{ bytes.Buffer }

func (b *limitedBuffer) Write(p []byte) (int, error) {
	const maximum = 1 << 20
	written := len(p)
	if b.Len() < maximum {
		remaining := maximum - b.Len()
		if len(p) > remaining {
			p = p[:remaining]
		}
		_, _ = b.Buffer.Write(p)
	}
	return written, nil
}

type HTTPSVerifier struct {
	Client *http.Client
	Wait   time.Duration
}

func (v HTTPSVerifier) Verify(ctx context.Context, cfg Config, adminSecret string) error {
	client := v.Client
	if client == nil {
		client = &http.Client{
			Timeout:       10 * time.Second,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
		}
	}
	wait := v.Wait
	if wait <= 0 {
		wait = 2 * time.Minute
	}
	deadline := time.Now().Add(wait)
	var last error
	for {
		if err := verifyPublicOnce(ctx, client, cfg.PublicURL, adminSecret); err == nil {
			return nil
		} else {
			last = err
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("public HTTPS verification did not succeed: %w", last)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(3 * time.Second):
		}
	}
}

func (v HTTPSVerifier) VerifyRoutes(ctx context.Context, cfg Config) error {
	client := v.Client
	if client == nil {
		client = &http.Client{
			Timeout:       10 * time.Second,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
		}
	}
	return verifyPublicRoutes(ctx, client, cfg.PublicURL)
}

func verifyPublicOnce(ctx context.Context, client *http.Client, origin, adminSecret string) error {
	if err := verifyPublicRoutes(ctx, client, origin); err != nil {
		return err
	}
	session, err := createAdminSession(ctx, client, origin, adminSecret)
	if err != nil {
		return err
	}
	return revokeAdminSession(ctx, client, origin, session)
}

func verifyPublicRoutes(ctx context.Context, client *http.Client, origin string) error {
	for _, path := range []string{"/healthz", "/v1/capabilities"} {
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSuffix(origin, "/")+path, nil)
		response, err := client.Do(req)
		if err != nil {
			return err
		}
		raw, _ := io.ReadAll(io.LimitReader(response.Body, 64<<10))
		response.Body.Close()
		if response.StatusCode != http.StatusOK {
			return fmt.Errorf("%s returned %s", path, response.Status)
		}
		if path == "/v1/capabilities" {
			var capability struct {
				Product   string `json:"product"`
				Component string `json:"component"`
				Protocol  struct {
					Major int `json:"major"`
				} `json:"protocol"`
			}
			if err := json.Unmarshal(raw, &capability); err != nil || capability.Product != "rctl" || capability.Component != "relay" {
				return errors.New("capability endpoint did not identify an rctl relay")
			}
			if capability.Protocol.Major != 1 {
				return fmt.Errorf("relay protocol major %d is incompatible with setup protocol major 1", capability.Protocol.Major)
			}
		}
	}
	if err := verifyWebSocketUpgrade(ctx, client, origin); err != nil {
		return err
	}
	return nil
}

func createAdminSession(ctx context.Context, client *http.Client, origin, adminSecret string) (*http.Cookie, error) {
	body, _ := json.Marshal(map[string]string{"secret": adminSecret})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimSuffix(origin, "/")+"/api/admin/login", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	response, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("admin login returned %s", response.Status)
	}
	var session *http.Cookie
	for _, cookie := range response.Cookies() {
		if cookie.Name == "rctl_session" && cookie.HttpOnly && cookie.Secure && cookie.Path == "/" && cookie.SameSite == http.SameSiteStrictMode {
			session = cookie
			break
		}
	}
	if session == nil {
		return nil, errors.New("admin login did not issue the required Secure HttpOnly SameSite=Strict session cookie")
	}
	return session, nil
}

func revokeAdminSession(ctx context.Context, client *http.Client, origin string, session *http.Cookie) error {
	logout, _ := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimSuffix(origin, "/")+"/api/admin/logout", nil)
	logout.AddCookie(session)
	logoutResponse, err := client.Do(logout)
	if err != nil {
		return fmt.Errorf("admin logout: %w", err)
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(logoutResponse.Body, 64<<10))
	logoutResponse.Body.Close()
	if logoutResponse.StatusCode != http.StatusOK {
		return fmt.Errorf("admin logout returned %s", logoutResponse.Status)
	}
	return nil
}

func verifyAdminSession(ctx context.Context, client *http.Client, origin string, session *http.Cookie) error {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSuffix(origin, "/")+"/api/admin/status", nil)
	req.AddCookie(session)
	response, err := client.Do(req)
	if err != nil {
		return err
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("persisted admin session returned %s", response.Status)
	}
	return nil
}

func verifyWebSocketUpgrade(ctx context.Context, client *http.Client, origin string) error {
	parsed, err := url.Parse(strings.TrimSuffix(origin, "/") + "/device")
	if err != nil {
		return err
	}
	parsed.Scheme = "wss"
	conn, response, err := websocket.Dial(ctx, parsed.String(), &websocket.DialOptions{HTTPClient: client})
	if err != nil {
		if response != nil {
			_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
			response.Body.Close()
			if response.StatusCode == http.StatusUnauthorized {
				return nil
			}
		}
		return fmt.Errorf("public WebSocket upgrade failed: %w", err)
	}
	return conn.Close(websocket.StatusNormalClosure, "setup route probe")
}

func (v HTTPSVerifier) VerifyPersistence(ctx context.Context, cfg Config, adminSecret string, restart func(context.Context) error) error {
	client := v.Client
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	}
	session, err := createAdminSession(ctx, client, cfg.PublicURL, adminSecret)
	if err != nil {
		return err
	}
	revoked := false
	defer func() {
		if !revoked {
			cleanupCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			_ = revokeAdminSession(cleanupCtx, client, cfg.PublicURL, session)
		}
	}()
	if err := restart(ctx); err != nil {
		return err
	}
	if err := verifyAdminSession(ctx, client, cfg.PublicURL, session); err != nil {
		return fmt.Errorf("relay SQLite session did not survive restart: %w", err)
	}
	if err := revokeAdminSession(ctx, client, cfg.PublicURL, session); err != nil {
		return err
	}
	revoked = true
	return nil
}

func (i Installer) Install(ctx context.Context, cfg Config, options InstallOptions) (result InstallResult, err error) {
	if err := cfg.Validate(); err != nil {
		return result, err
	}
	if i.Paths.EtcDir == "" {
		i.Paths = DefaultPaths()
	}
	if i.Runner == nil {
		i.Runner = OSRunner{}
	}
	if i.Verifier == nil {
		i.Verifier = HTTPSVerifier{}
	}
	if i.Now == nil {
		i.Now = time.Now
	}
	if i.Chown == nil {
		i.Chown = os.Chown
	}
	if options.Version == "" {
		options.Version = "dev"
	}
	if !options.DryRun {
		releaseLock, err := acquireLifecycleLock(i.Paths.LockPath)
		if err != nil {
			return result, err
		}
		defer releaseLock()
	}
	if err := ensureNoPendingRecovery(i.Paths); err != nil {
		return result, err
	}

	existing, manifestErr := loadManifest(i.Paths.ManifestPath)
	if manifestErr != nil && !errors.Is(manifestErr, os.ErrNotExist) {
		return result, manifestErr
	}
	if manifestErr == nil {
		if err := validateOwnershipManifest(existing, i.Paths); err != nil {
			return result, err
		}
		if !configsEqual(existing.Config, cfg) {
			return result, errors.New("installed configuration differs; use transactional upgrade/reconfigure")
		}
		if err := verifyOwnedFiles(existing); err != nil {
			return result, err
		}
		secrets, err := readExistingSecrets(i.Paths.RelayEnv)
		if err != nil {
			return result, err
		}
		if options.DryRun {
			return InstallResult{DryRun: true, Files: ownedPaths(existing.Files)}, nil
		}
		if err := i.verifyServices(ctx, cfg, secrets.Admin, false); err != nil {
			return result, err
		}
		return InstallResult{Fresh: false, Files: ownedPaths(existing.Files)}, nil
	}
	if err := ensureNoForeignState(i.Paths); err != nil {
		return result, err
	}
	secrets, err := GenerateSecrets(i.Random)
	if err != nil {
		return result, err
	}
	bundle, err := RenderDedicatedBundleAt(cfg, secrets, i.Paths)
	if err != nil {
		return result, err
	}
	if cfg.DevicePackages {
		packageData, packageInfo, packageErr := readPublicPackageSource(options.PublicPackageSource)
		if packageErr != nil {
			return result, packageErr
		}
		if cfg.Release != "" && cfg.Release != "dev" && packageInfo.Version != cfg.Release {
			return result, fmt.Errorf("public device package version %q does not match setup release %q", packageInfo.Version, cfg.Release)
		}
		bundle.Files = append(bundle.Files, File{Path: i.Paths.PublicPackage, Mode: 0o644, Content: packageData})
	}
	result.Files = bundlePaths(bundle)
	if options.DryRun {
		result.DryRun = true
		return result, nil
	}

	started := i.Now().Unix()
	operationID := fmt.Sprintf("install-%d", started)
	journalPath := filepath.Join(i.Paths.LogDir, operationID+".json")
	journal := Journal{Schema: 1, Operation: "install", Status: "running", Stage: "prepare", StartedAt: started, UpdatedAt: started}
	committed := false
	defer func() {
		if committed || err == nil {
			return
		}
		recoveryCtx, cancel := lifecycleRecoveryContext()
		defer cancel()
		journal.Status = "rolled_back"
		journal.Stage = "rollback"
		journal.UpdatedAt = i.Now().Unix()
		journal.Error = redact(err.Error(), secrets)
		_ = i.stopFreshServices(recoveryCtx)
		_ = rollbackFresh(i.Paths, bundle)
		_ = clearRecovery(i.Paths)
		_ = writeJSONAtomic(journalPath, journal, 0o600)
	}()
	if err = beginRecovery(i.Paths, "install", "", i.Now()); err != nil {
		return result, err
	}
	if err = i.prepareDirectories(); err != nil {
		return result, err
	}
	if err = writeJSONAtomic(journalPath, journal, 0o600); err != nil {
		return result, err
	}

	journal.Stage = "write_files"
	journal.UpdatedAt = i.Now().Unix()
	_ = writeJSONAtomic(journalPath, journal, 0o600)
	for _, file := range bundle.Files {
		if err = writeFileAtomic(file.Path, file.Content, os.FileMode(file.Mode)); err != nil {
			return result, err
		}
	}
	if err = applyRuntimeOwnership(cfg, i.Paths, i.Chown); err != nil {
		return result, err
	}
	journal.Stage = "validate_and_start"
	journal.UpdatedAt = i.Now().Unix()
	_ = writeJSONAtomic(journalPath, journal, 0o600)
	if err = i.verifyServices(ctx, cfg, secrets.Admin, true); err != nil {
		err = fmt.Errorf("deployment verification failed: %s", redact(err.Error(), secrets))
		return result, err
	}

	manifest := manifestFor(cfg, bundle, options.Version, started, i.Now().Unix())
	if err = writeJSONAtomic(i.Paths.ManifestPath, manifest, 0o600); err != nil {
		return result, err
	}
	journal.Status = "complete"
	journal.Stage = "commit"
	journal.UpdatedAt = i.Now().Unix()
	journal.Error = ""
	if err = writeJSONAtomic(journalPath, journal, 0o600); err != nil {
		return result, err
	}
	if err = clearRecovery(i.Paths); err != nil {
		return result, err
	}
	committed = true
	result.Fresh = true
	result.AdminSecret = secrets.Admin
	return result, nil
}

func lifecycleRecoveryContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 5*time.Minute)
}

func acquireLifecycleLock(name string) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		return nil, fmt.Errorf("create lock directory: %w", err)
	}
	lock, err := os.OpenFile(name, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open setup lock: %w", err)
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, errors.New("another rctl lifecycle operation is active")
	}
	return func() {
		_ = syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
		_ = lock.Close()
	}, nil
}

func (i Installer) prepareDirectories() error {
	directories := []struct {
		path string
		mode os.FileMode
	}{
		{i.Paths.EtcDir, 0o700}, {i.Paths.OptDir, 0o755}, {i.Paths.DataDir, 0o700},
		{i.Paths.RelayDataDir, 0o750}, {i.Paths.CaddyDataDir, 0o700}, {i.Paths.CaddyConfDir, 0o700},
		{i.Paths.BackupDir, 0o700}, {i.Paths.LogDir, 0o700}, {i.Paths.StateDir, 0o700},
	}
	for _, dir := range directories {
		if info, err := os.Lstat(dir.path); err == nil {
			if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
				return fmt.Errorf("managed directory path is not a real directory: %s", dir.path)
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("inspect %s: %w", dir.path, err)
		}
		if err := os.MkdirAll(dir.path, dir.mode); err != nil {
			return fmt.Errorf("create %s: %w", dir.path, err)
		}
		if err := os.Chmod(dir.path, dir.mode); err != nil {
			return fmt.Errorf("chmod %s: %w", dir.path, err)
		}
	}
	if err := i.Chown(i.Paths.RelayDataDir, relayRuntimeUID, relayRuntimeGID); err != nil {
		return fmt.Errorf("chown relay data: %w", err)
	}
	return nil
}

func applyRuntimeOwnership(cfg Config, paths Paths, chown Chowner) error {
	if !cfg.EnableTURN {
		return nil
	}
	if chown == nil {
		chown = os.Chown
	}
	if err := chown(paths.Coturn, coturnRuntimeUID, coturnRuntimeGID); err != nil {
		return fmt.Errorf("chown coturn config: %w", err)
	}
	return nil
}

func (i Installer) composeArgs(extra ...string) []string {
	base := []string{"compose", "--project-name", "rctl", "--file", i.Paths.Compose}
	return append(base, extra...)
}

func (i Installer) verifyServices(ctx context.Context, cfg Config, adminSecret string, start bool) error {
	if start {
		if output, err := i.Runner.Run(ctx, "docker", i.composeArgs("config", "--quiet")...); err != nil {
			return fmt.Errorf("compose validation: %s", commandFailure(output, err))
		}
		if output, err := i.Runner.Run(ctx, "docker", i.composeArgs("pull")...); err != nil {
			return fmt.Errorf("image pull: %s", commandFailure(output, err))
		}
		if output, err := i.Runner.Run(ctx, "docker", "run", "--rm", "--network", "none", "-v", i.Paths.Caddyfile+":/etc/caddy/Caddyfile:ro", cfg.CaddyImage, "caddy", "validate", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"); err != nil {
			return fmt.Errorf("Caddy validation: %s", commandFailure(output, err))
		}
		if output, err := i.Runner.Run(ctx, "docker", i.composeArgs("up", "-d", "--remove-orphans")...); err != nil {
			return fmt.Errorf("service start: %s", commandFailure(output, err))
		}
	}
	if err := i.waitForServices(ctx, cfg.EnableTURN); err != nil {
		return err
	}
	if err := i.Verifier.Verify(ctx, cfg, adminSecret); err != nil {
		return err
	}
	if start {
		restart := func(restartCtx context.Context) error {
			if output, err := i.Runner.Run(restartCtx, "docker", i.composeArgs("restart", "relay")...); err != nil {
				return fmt.Errorf("relay persistence restart: %s", commandFailure(output, err))
			}
			if err := i.waitForServices(restartCtx, cfg.EnableTURN); err != nil {
				return fmt.Errorf("post-restart health: %w", err)
			}
			return nil
		}
		if err := i.Verifier.VerifyPersistence(ctx, cfg, adminSecret, restart); err != nil {
			return fmt.Errorf("post-restart persistence: %w", err)
		}
	}
	return nil
}

func (i Installer) waitForServices(ctx context.Context, turn bool) error {
	var last string
	for attempt := 0; attempt < 40; attempt++ {
		output, err := i.Runner.Run(ctx, "docker", i.composeArgs("ps", "--all", "--format", "json")...)
		last = output
		if err == nil {
			states, parseErr := parseComposePS(output)
			if parseErr == nil {
				parseErr = requireHealthyServices(states, turn)
			}
			if parseErr == nil {
				return nil
			}
			last = parseErr.Error()
		} else {
			last = commandFailure(output, err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(3 * time.Second):
		}
	}
	return fmt.Errorf("services did not become healthy: %s", last)
}

type composeServiceState struct {
	Service string `json:"Service"`
	State   string `json:"State"`
	Health  string `json:"Health"`
}

func parseComposePS(raw string) (map[string]composeServiceState, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, errors.New("docker compose reported no containers")
	}
	items := make([]composeServiceState, 0, 3)
	if strings.HasPrefix(raw, "[") {
		if err := json.Unmarshal([]byte(raw), &items); err != nil {
			return nil, fmt.Errorf("decode docker compose service state: %w", err)
		}
	} else {
		decoder := json.NewDecoder(strings.NewReader(raw))
		for {
			var item composeServiceState
			if err := decoder.Decode(&item); errors.Is(err, io.EOF) {
				break
			} else if err != nil {
				return nil, fmt.Errorf("decode docker compose service state: %w", err)
			}
			items = append(items, item)
		}
	}
	states := make(map[string]composeServiceState, len(items))
	for _, item := range items {
		if item.Service == "" || item.State == "" {
			return nil, errors.New("docker compose returned an incomplete service record")
		}
		if _, exists := states[item.Service]; exists {
			return nil, fmt.Errorf("docker compose returned multiple containers for service %s", item.Service)
		}
		states[item.Service] = item
	}
	return states, nil
}

func requireHealthyServices(states map[string]composeServiceState, turn bool) error {
	wanted := []string{"relay", "caddy"}
	if turn {
		wanted = append(wanted, "coturn")
	}
	for _, name := range wanted {
		state, ok := states[name]
		if !ok {
			return fmt.Errorf("required service %s has no container", name)
		}
		if state.State != "running" {
			return fmt.Errorf("required service %s is %s", name, state.State)
		}
		if (name == "relay" || name == "coturn") && state.Health != "healthy" {
			return fmt.Errorf("required service %s health is %s", name, emptyAs(state.Health, "missing"))
		}
		if name == "caddy" && state.Health != "" && state.Health != "healthy" {
			return fmt.Errorf("required service caddy health is %s", state.Health)
		}
	}
	return nil
}

func (i Installer) stopFreshServices(ctx context.Context) error {
	if _, err := os.Stat(i.Paths.Compose); err != nil {
		return nil
	}
	_, err := i.Runner.Run(ctx, "docker", i.composeArgs("down", "--remove-orphans")...)
	return err
}

func ensureNoForeignState(paths Paths) error {
	for _, path := range []string{paths.EtcDir, paths.OptDir, paths.DataDir, paths.BackupDir} {
		if _, err := os.Lstat(path); err == nil {
			return fmt.Errorf("unowned existing path %s; refusing to overwrite", path)
		} else if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("inspect %s: %w", path, err)
		}
	}
	if info, err := os.Lstat(paths.LogDir); err == nil {
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("existing setup journal path is not a real directory: %s", paths.LogDir)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect %s: %w", paths.LogDir, err)
	}
	return nil
}

func manifestFor(cfg Config, bundle Bundle, version string, created, updated int64) OwnershipManifest {
	files := make([]OwnedFile, 0, len(bundle.Files))
	for _, file := range bundle.Files {
		digest := sha256.Sum256(file.Content)
		files = append(files, OwnedFile{Path: file.Path, Mode: file.Mode, SHA256: hex.EncodeToString(digest[:]), Secret: file.Secret})
	}
	sort.Slice(files, func(a, b int) bool { return files[a].Path < files[b].Path })
	return OwnershipManifest{Schema: ownershipSchema, Product: "rctl", Version: version, CreatedAt: created, UpdatedAt: updated, Config: cfg, Files: files}
}

func loadManifest(path string) (OwnershipManifest, error) {
	var manifest OwnershipManifest
	raw, err := readRegularFile(path, 1<<20, 0o600)
	if err != nil {
		return manifest, err
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&manifest); err != nil {
		return manifest, fmt.Errorf("decode ownership manifest: %w", err)
	}
	if manifest.Schema != ownershipSchema || manifest.Product != "rctl" {
		return manifest, errors.New("ownership manifest is incompatible")
	}
	var trailing any
	if err := dec.Decode(&trailing); !errors.Is(err, io.EOF) {
		return manifest, errors.New("ownership manifest contains trailing data")
	}
	return manifest, nil
}

func validateOwnershipManifest(manifest OwnershipManifest, paths Paths) error {
	if err := manifest.Config.Validate(); err != nil {
		return fmt.Errorf("ownership manifest configuration: %w", err)
	}
	if manifest.Config.Profile != ProfileContainer {
		return errors.New("ownership manifest has an unsupported deployment profile")
	}
	if manifest.Version == "" || len(manifest.Version) > 128 || strings.ContainsAny(manifest.Version, "\r\n\x00") {
		return errors.New("ownership manifest has invalid version metadata")
	}
	if manifest.CreatedAt <= 0 || manifest.UpdatedAt < manifest.CreatedAt {
		return errors.New("ownership manifest has invalid timestamps")
	}
	allowed := map[string]struct {
		mode   uint32
		secret bool
	}{
		paths.RelayEnv:  {0o600, true},
		paths.Compose:   {0o644, false},
		paths.Caddyfile: {0o644, false},
	}
	if manifest.Config.EnableTURN {
		allowed[paths.Coturn] = struct {
			mode   uint32
			secret bool
		}{0o600, true}
	}
	if manifest.Config.DevicePackages {
		allowed[paths.PublicPackage] = struct {
			mode   uint32
			secret bool
		}{0o644, false}
	}
	if len(manifest.Files) != len(allowed) {
		return errors.New("ownership manifest file set is incompatible")
	}
	seen := make(map[string]bool, len(manifest.Files))
	for _, file := range manifest.Files {
		expected, ok := allowed[file.Path]
		if !ok || seen[file.Path] || file.Mode != expected.mode || file.Secret != expected.secret {
			return fmt.Errorf("ownership manifest contains unexpected file metadata for %s", file.Path)
		}
		if len(file.SHA256) != sha256.Size*2 {
			return fmt.Errorf("ownership manifest contains an invalid digest for %s", file.Path)
		}
		if _, err := hex.DecodeString(file.SHA256); err != nil {
			return fmt.Errorf("ownership manifest contains an invalid digest for %s", file.Path)
		}
		seen[file.Path] = true
	}
	return nil
}

func verifyOwnedFiles(manifest OwnershipManifest) error {
	for _, owned := range manifest.Files {
		raw, err := readRegularFile(owned.Path, deb.MaxPackageBytes, os.FileMode(owned.Mode))
		if err != nil {
			return fmt.Errorf("owned file %s: %w", owned.Path, err)
		}
		digest := sha256.Sum256(raw)
		if hex.EncodeToString(digest[:]) != owned.SHA256 {
			return fmt.Errorf("owned file %s was modified outside rctl-setup", owned.Path)
		}
	}
	return nil
}

func readPublicPackageSource(name string) ([]byte, deb.Info, error) {
	if name == "" {
		return nil, deb.Info{}, errors.New("public device package is required when device package generation is enabled")
	}
	raw, err := readRegularFile(name, deb.MaxPackageBytes, 0)
	if err != nil {
		return nil, deb.Info{}, fmt.Errorf("read public device package: %w", err)
	}
	info, err := deb.Inspect(raw)
	if err != nil {
		return nil, deb.Info{}, fmt.Errorf("validate public device package: %w", err)
	}
	return raw, info, nil
}

func readRegularFile(path string, maximum int64, exactMode os.FileMode) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("not a regular file")
	}
	if info.Size() > maximum {
		return nil, errors.New("file exceeds size limit")
	}
	if exactMode != 0 && info.Mode().Perm() != exactMode.Perm() {
		return nil, fmt.Errorf("mode is %o, expected %o", info.Mode().Perm(), exactMode.Perm())
	}
	return os.ReadFile(path)
}

func readExistingSecrets(path string) (Secrets, error) {
	raw, err := readRegularFile(path, 1<<20, 0o600)
	if err != nil {
		return Secrets{}, fmt.Errorf("read existing relay identity: %w", err)
	}
	values := make(map[string]string)
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	for scanner.Scan() {
		key, value, ok := strings.Cut(scanner.Text(), "=")
		if ok {
			values[key] = value
		}
	}
	secrets := Secrets{Admin: values["RCTL_RELAY_ADMIN_SECRET"], Session: values["RCTL_RELAY_SESSION_SECRET"], TURN: values["RCTL_RELAY_TURN_SECRET"]}
	if len(secrets.Admin) < 48 || len(secrets.Session) < 48 {
		return Secrets{}, errors.New("existing relay secrets are missing or invalid")
	}
	return secrets, nil
}

func writeJSONAtomic(path string, value any, mode os.FileMode) error {
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	return writeFileAtomic(path, raw, mode)
}

func writeFileAtomic(path string, content []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	file, err := os.CreateTemp(dir, ".rctl-setup-*")
	if err != nil {
		return fmt.Errorf("create candidate for %s: %w", path, err)
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	if err := file.Chmod(mode); err != nil {
		file.Close()
		return err
	}
	if _, err := file.Write(content); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		return fmt.Errorf("install %s: %w", path, err)
	}
	directory, err := os.Open(dir)
	if err == nil {
		err = directory.Sync()
		directory.Close()
	}
	return err
}

func rollbackFresh(paths Paths, bundle Bundle) error {
	for _, file := range bundle.Files {
		_ = os.Remove(file.Path)
	}
	_ = os.Remove(paths.ManifestPath)
	for _, path := range []string{paths.OptDir, paths.EtcDir, paths.DataDir, paths.BackupDir} {
		_ = os.RemoveAll(path)
	}
	return nil
}

func configsEqual(a, b Config) bool {
	aRaw, _ := json.Marshal(a)
	bRaw, _ := json.Marshal(b)
	return bytes.Equal(aRaw, bRaw)
}

func ownedPaths(files []OwnedFile) []string {
	paths := make([]string, 0, len(files))
	for _, file := range files {
		paths = append(paths, file.Path)
	}
	sort.Strings(paths)
	return paths
}

func bundlePaths(bundle Bundle) []string {
	paths := make([]string, 0, len(bundle.Files))
	for _, file := range bundle.Files {
		paths = append(paths, file.Path)
	}
	sort.Strings(paths)
	return paths
}

func redact(message string, secrets Secrets) string {
	for _, secret := range []string{secrets.Admin, secrets.Session, secrets.TURN} {
		if secret != "" {
			message = strings.ReplaceAll(message, secret, "[REDACTED]")
		}
	}
	return message
}

func commandFailure(output string, err error) string {
	if output != "" {
		return output
	}
	return err.Error()
}
