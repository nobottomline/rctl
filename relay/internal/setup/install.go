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
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
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
}

type Chowner func(path string, uid, gid int) error

type Installer struct {
	Paths    Paths
	Runner   Runner
	Verifier PublicVerifier
	Random   io.Reader
	Now      func() time.Time
	Chown    Chowner
}

type InstallOptions struct {
	DryRun  bool
	Version string
}

type InstallResult struct {
	Fresh       bool
	DryRun      bool
	AdminSecret string
	Files       []string
}

type OSRunner struct{}

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

func verifyPublicOnce(ctx context.Context, client *http.Client, origin, adminSecret string) error {
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
			}
			if err := json.Unmarshal(raw, &capability); err != nil || capability.Product != "rctl" || capability.Component != "relay" {
				return errors.New("capability endpoint did not identify an rctl relay")
			}
		}
	}
	body, _ := json.Marshal(map[string]string{"secret": adminSecret})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimSuffix(origin, "/")+"/api/admin/login", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	response, err := client.Do(req)
	if err != nil {
		return err
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("admin login returned %s", response.Status)
	}
	var session *http.Cookie
	for _, cookie := range response.Cookies() {
		if cookie.HttpOnly && cookie.Secure {
			session = cookie
			break
		}
	}
	if session == nil {
		return errors.New("admin login did not issue a Secure HttpOnly session cookie")
	}
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
	if err := os.MkdirAll(filepath.Dir(i.Paths.LockPath), 0o755); err != nil {
		return result, fmt.Errorf("create lock directory: %w", err)
	}
	lock, err := os.OpenFile(i.Paths.LockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return result, fmt.Errorf("open setup lock: %w", err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return result, errors.New("another rctl lifecycle operation is active")
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)

	existing, manifestErr := loadManifest(i.Paths.ManifestPath)
	if manifestErr != nil && !errors.Is(manifestErr, os.ErrNotExist) {
		return result, manifestErr
	}
	if manifestErr == nil {
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
		journal.Status = "rolled_back"
		journal.Stage = "rollback"
		journal.UpdatedAt = i.Now().Unix()
		journal.Error = redact(err.Error(), secrets)
		_ = i.stopFreshServices(context.Background())
		_ = rollbackFresh(i.Paths, bundle)
		_ = writeJSONAtomic(journalPath, journal, 0o600)
	}()
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
	committed = true
	result.Fresh = true
	result.AdminSecret = secrets.Admin
	return result, nil
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
		if err := os.MkdirAll(dir.path, dir.mode); err != nil {
			return fmt.Errorf("create %s: %w", dir.path, err)
		}
		if err := os.Chmod(dir.path, dir.mode); err != nil {
			return fmt.Errorf("chmod %s: %w", dir.path, err)
		}
	}
	if err := i.Chown(i.Paths.RelayDataDir, 65532, 65532); err != nil {
		return fmt.Errorf("chown relay data: %w", err)
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
		if output, err := i.Runner.Run(ctx, "docker", i.composeArgs("restart", "relay")...); err != nil {
			return fmt.Errorf("relay persistence restart: %s", commandFailure(output, err))
		}
		if err := i.waitForServices(ctx, cfg.EnableTURN); err != nil {
			return fmt.Errorf("post-restart health: %w", err)
		}
		if err := i.Verifier.Verify(ctx, cfg, adminSecret); err != nil {
			return fmt.Errorf("post-restart public health: %w", err)
		}
	}
	return nil
}

func (i Installer) waitForServices(ctx context.Context, turn bool) error {
	wanted := map[string]bool{"relay": false, "caddy": false}
	if turn {
		wanted["coturn"] = false
	}
	var last string
	for attempt := 0; attempt < 40; attempt++ {
		output, err := i.Runner.Run(ctx, "docker", i.composeArgs("ps", "--status", "running", "--services")...)
		last = output
		if err == nil {
			for key := range wanted {
				wanted[key] = false
			}
			for _, service := range strings.Fields(output) {
				if _, ok := wanted[service]; ok {
					wanted[service] = true
				}
			}
			complete := true
			for _, found := range wanted {
				complete = complete && found
			}
			if complete {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(3 * time.Second):
		}
	}
	return fmt.Errorf("services did not reach running state: %s", last)
}

func (i Installer) stopFreshServices(ctx context.Context) error {
	if _, err := os.Stat(i.Paths.Compose); err != nil {
		return nil
	}
	_, err := i.Runner.Run(ctx, "docker", i.composeArgs("down", "--remove-orphans")...)
	return err
}

func ensureNoForeignState(paths Paths) error {
	for _, path := range []string{paths.EtcDir, paths.OptDir, paths.DataDir, paths.BackupDir, paths.LogDir} {
		if _, err := os.Lstat(path); err == nil {
			return fmt.Errorf("unowned existing path %s; refusing to overwrite", path)
		} else if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("inspect %s: %w", path, err)
		}
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
	return manifest, nil
}

func verifyOwnedFiles(manifest OwnershipManifest) error {
	for _, owned := range manifest.Files {
		raw, err := readRegularFile(owned.Path, 64<<20, os.FileMode(owned.Mode))
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
