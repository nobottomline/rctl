package setup

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

// DockerDependencies installs only onto a host without an existing container
// runtime. It never repairs/removes an operator's packages, data or services.
type DockerDependencies struct {
	Root     string
	Runner   Runner
	LookPath func(string) (string, error)
	Fetch    func(context.Context, string) ([]byte, error)
}

type DockerDependencyPlan struct {
	Distro, Suite, Arch string
}

func (d DockerDependencies) path(name string) string { return filepath.Join(d.Root, name) }

func (d DockerDependencies) Plan(ctx context.Context) (DockerDependencyPlan, error) {
	var plan DockerDependencyPlan
	lookPath := d.LookPath
	if lookPath == nil {
		lookPath = exec.LookPath
	}
	if _, err := lookPath("docker"); !errors.Is(err, exec.ErrNotFound) {
		return plan, errors.New("Docker already exists or its executable cannot be inspected; repair the existing runtime manually")
	}
	raw, err := os.ReadFile(d.path("/etc/os-release"))
	if err != nil {
		return plan, err
	}
	values := parseKeyValue(string(raw))
	plan = DockerDependencyPlan{Distro: values["ID"], Suite: values["VERSION_CODENAME"], Arch: runtime.GOARCH}
	if plan.Distro != "ubuntu" && plan.Distro != "debian" {
		return plan, errors.New("automatic Docker installation supports Ubuntu and Debian only")
	}
	if plan.Arch != "amd64" && plan.Arch != "arm64" {
		return plan, errors.New("automatic Docker installation supports amd64 and arm64 only")
	}
	if plan.Suite == "" || strings.Trim(plan.Suite, "abcdefghijklmnopqrstuvwxyz0123456789-") != "" {
		return plan, errors.New("cannot determine the distribution codename")
	}
	if _, err := os.Stat(d.path("/run/systemd/system")); err != nil {
		return plan, errors.New("automatic Docker installation requires a systemd host")
	}
	for _, name := range []string{"/var/lib/docker", "/var/lib/containerd", "/etc/docker/daemon.json", "/etc/containerd/config.toml"} {
		if _, err := os.Lstat(d.path(name)); !errors.Is(err, os.ErrNotExist) {
			return plan, fmt.Errorf("existing container runtime state at %s; automatic installation refused", name)
		}
	}
	sources := []string{d.path("/etc/apt/sources.list")}
	for _, pattern := range []string{"/etc/apt/sources.list.d/*.list", "/etc/apt/sources.list.d/*.sources"} {
		matches, err := filepath.Glob(d.path(pattern))
		if err != nil {
			return plan, err
		}
		sources = append(sources, matches...)
	}
	for _, path := range sources {
		if path == d.path("/etc/apt/sources.list.d/rctl-docker.sources") {
			continue
		}
		raw, err := readSmallSetupFile(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return plan, errors.New("cannot safely inspect existing APT sources")
		}
		if strings.Contains(string(raw), "download.docker.com") {
			return plan, errors.New("an existing Docker APT source requires manual inspection; automatic installation refused")
		}
	}
	runner := d.Runner
	if runner == nil {
		runner = OSRunner{}
	}
	if audit, err := runner.Run(ctx, "dpkg", "--audit"); err != nil || strings.TrimSpace(audit) != "" {
		return plan, errors.New("dpkg reports unfinished package configuration; resolve it before installing Docker")
	}
	packages, err := runner.Run(ctx, "dpkg-query", "-W", "-f=${binary:Package}\t${db:Status-Status}\n")
	if err != nil {
		return plan, errors.New("cannot inspect installed packages")
	}
	conflicts := map[string]bool{"docker.io": true, "docker-ce": true, "docker-ce-cli": true, "docker-compose": true, "docker-compose-v2": true, "docker-compose-plugin": true, "podman-docker": true, "containerd": true, "containerd.io": true, "runc": true}
	for _, line := range strings.Split(packages, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 {
			name, _, _ := strings.Cut(fields[0], ":")
			if conflicts[name] && fields[1] != "not-installed" && fields[1] != "config-files" {
				return plan, fmt.Errorf("existing runtime package %s (%s); automatic installation refused", name, fields[1])
			}
		}
	}
	return plan, nil
}

func (d DockerDependencies) Install(ctx context.Context, expected DockerDependencyPlan, progress ProgressFunc) error {
	plan, err := d.Plan(ctx)
	if err != nil {
		return err
	}
	if plan != expected {
		return errors.New("host changed since Docker installation was confirmed")
	}
	fetch := d.Fetch
	if fetch == nil {
		fetch = fetchDockerMetadata
	}
	base := "https://download.docker.com/linux/" + plan.Distro
	if progress != nil {
		progress("Checking the official Docker repository")
	}
	if _, err := fetch(ctx, base+"/dists/"+plan.Suite+"/Release"); err != nil {
		return fmt.Errorf("Docker repository is unavailable for this distribution; no package sources changed: %w", err)
	}
	key, err := fetch(ctx, base+"/gpg")
	if err != nil || !strings.HasPrefix(string(key), "-----BEGIN PGP PUBLIC KEY BLOCK-----") {
		return errors.New("could not fetch the official Docker repository signing key")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	keyPath := "/etc/apt/keyrings/rctl-docker.asc"
	sourcePath := "/etc/apt/sources.list.d/rctl-docker.sources"
	source := fmt.Sprintf("Types: deb\nURIs: %s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: %s\n", base, plan.Suite, plan.Arch, keyPath)
	// A known source can be resumed after a download failure. Never overwrite a
	// different source/key or follow a symlink at either managed file.
	for _, item := range []struct {
		name string
		data []byte
	}{{keyPath, key}, {sourcePath, []byte(source)}} {
		if err := writeDependencyFile(d.path(item.name), item.data); err != nil {
			return fmt.Errorf("Docker repository: %w", err)
		}
	}
	runner := d.Runner
	if runner == nil {
		runner = dependencyRunner{}
	}
	steps := []struct {
		label, name string
		args        []string
	}{
		{"Refreshing APT metadata", "apt-get", []string{"-o", "DPkg::Lock::Timeout=60", "-o", "APT::Update::Error-Mode=any", "-o", "Acquire::Retries=2", "-o", "Acquire::https::Timeout=30", "-o", "Acquire::http::Timeout=30", "update"}},
		{"Installing Docker Engine and Compose (package transactions finish before cancellation)", "apt-get", []string{"-o", "DPkg::Lock::Timeout=60", "-o", "Acquire::Retries=2", "-o", "Acquire::https::Timeout=30", "--no-remove", "--no-install-recommends", "-y", "install", "docker-ce", "docker-ce-cli", "containerd.io", "docker-compose-plugin"}},
		{"Starting Docker", "systemctl", []string{"enable", "--now", "docker"}},
		{"Checking Docker Engine", "docker", []string{"version", "--format", "{{.Server.Version}}"}},
		{"Checking Compose", "docker", []string{"compose", "version", "--short"}},
	}
	for _, step := range steps {
		if err := ctx.Err(); err != nil {
			return err
		}
		if progress != nil {
			progress(step.label)
		}
		if _, err := runner.Run(ctx, step.name, step.args...); err != nil {
			return fmt.Errorf("%s failed: %w; package changes are retained, inspect APT/systemd before retrying", step.label, err)
		}
	}
	return nil
}

func writeDependencyFile(path string, content []byte) error {
	if info, err := os.Lstat(path); err == nil {
		if !info.Mode().IsRegular() {
			return errors.New("refusing an existing non-regular file")
		}
		previous, err := os.ReadFile(path)
		if err != nil || string(previous) != string(content) {
			return errors.New("refusing to replace a different repository file")
		}
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	directory := filepath.Dir(path)
	_, statErr := os.Stat(directory)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return err
	}
	if errors.Is(statErr, os.ErrNotExist) {
		if err := os.Chmod(directory, 0o755); err != nil {
			return err
		}
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	// Bootstrap deliberately uses umask 077; APT's _apt user must read the key.
	modeErr := file.Chmod(0o644)
	_, writeErr := file.Write(content)
	syncErr := file.Sync()
	closeErr := file.Close()
	err = errors.Join(modeErr, writeErr, syncErr, closeErr)
	if err != nil {
		_ = os.Remove(path)
	}
	return err
}

func fetchDockerMetadata(ctx context.Context, target string) ([]byte, error) {
	client := &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, err
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", response.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, (1<<20)+1))
	if len(raw) > 1<<20 {
		return nil, errors.New("repository metadata exceeds size limit")
	}
	return raw, err
}

type dependencyRunner struct{}

func (dependencyRunner) Run(ctx context.Context, name string, args ...string) (string, error) {
	if name != "apt-get" {
		return (OSRunner{}).Run(ctx, name, args...)
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	// Killing apt's parent while dpkg runs can corrupt package state. Finish the
	// current transaction, then honor cancellation before the next step.
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Env = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C", "LC_ALL=C", "DEBIAN_FRONTEND=noninteractive"}
	var output limitedBuffer
	cmd.Stdout, cmd.Stderr = &output, &output
	if err := cmd.Run(); err != nil {
		return "", err
	}
	return "", ctx.Err()
}
