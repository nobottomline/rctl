package setup

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type dependencyTestRunner struct {
	packages string
	audit    string
	commands []string
	fail     string
	cancel   context.CancelFunc
}

func (r *dependencyTestRunner) Run(_ context.Context, name string, args ...string) (string, error) {
	if name == "dpkg" {
		return r.audit, nil
	}
	if name == "dpkg-query" {
		return r.packages, nil
	}
	command := name + " " + strings.Join(args, " ")
	r.commands = append(r.commands, command)
	if strings.Contains(command, r.fail) && r.fail != "" {
		return "", errors.New("fixture failure")
	}
	if r.cancel != nil && strings.HasSuffix(command, " update") {
		r.cancel()
	}
	return "ok", nil
}

func dependencyFixture(t *testing.T) (DockerDependencies, *dependencyTestRunner) {
	t.Helper()
	root := t.TempDir()
	for _, directory := range []string{"etc/apt", "run/systemd/system"} {
		if err := os.MkdirAll(filepath.Join(root, directory), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "etc/os-release"), []byte("ID=ubuntu\nVERSION_CODENAME=noble\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := &dependencyTestRunner{}
	return DockerDependencies{Root: root, Runner: runner, LookPath: func(string) (string, error) { return "", exec.ErrNotFound }, Fetch: func(_ context.Context, target string) ([]byte, error) {
		if !strings.HasPrefix(target, "https://download.docker.com/linux/ubuntu/") {
			t.Fatalf("unexpected origin: %s", target)
		}
		if strings.HasSuffix(target, "/gpg") {
			return []byte("-----BEGIN PGP PUBLIC KEY BLOCK-----\nfixture"), nil
		}
		return []byte("Origin: Docker"), nil
	}}, runner
}

func TestDockerDependencyPlanDoesNotMutate(t *testing.T) {
	d, r := dependencyFixture(t)
	plan, err := d.Plan(context.Background())
	if err != nil || plan.Distro != "ubuntu" || plan.Suite != "noble" {
		t.Fatalf("%#v %v", plan, err)
	}
	if len(r.commands) != 0 {
		t.Fatal(r.commands)
	}
	if _, err := os.Stat(d.path("/etc/apt/keyrings")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("plan wrote keyring")
	}
}

func TestDockerDependencyInstallerRefusesExistingRuntime(t *testing.T) {
	for _, state := range []string{"binary", "package", "data", "config", "source", "audit"} {
		t.Run(state, func(t *testing.T) {
			d, r := dependencyFixture(t)
			switch state {
			case "audit":
				r.audit = "unfinished package"
			case "binary":
				d.LookPath = func(string) (string, error) { return "/usr/bin/docker", nil }
			case "package":
				r.packages = "containerd:amd64\tinstalled\n"
			case "data":
				if err := os.MkdirAll(d.path("/var/lib/docker"), 0o755); err != nil {
					t.Fatal(err)
				}
			case "config":
				if err := os.MkdirAll(d.path("/etc/docker"), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(d.path("/etc/docker/daemon.json"), []byte("{}"), 0o644); err != nil {
					t.Fatal(err)
				}
			case "source":
				if err := os.WriteFile(d.path("/etc/apt/sources.list"), []byte("deb https://download.docker.com/linux/ubuntu noble stable"), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := d.Plan(context.Background()); err == nil {
				t.Fatal("unsafe plan accepted")
			}
			if len(r.commands) != 0 {
				t.Fatal(r.commands)
			}
		})
	}
}

func TestDockerDependenciesInstallAndVerifyWithoutRemoval(t *testing.T) {
	d, r := dependencyFixture(t)
	plan, err := d.Plan(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := d.Install(context.Background(), plan, nil); err != nil {
		t.Fatal(err)
	}
	if len(r.commands) != 5 {
		t.Fatal(r.commands)
	}
	if !strings.Contains(r.commands[1], "--no-remove") || !strings.Contains(r.commands[1], "docker-compose-plugin") {
		t.Fatal(r.commands)
	}
	want := []string{"systemctl enable --now docker", "docker version --format {{.Server.Version}}", "docker compose version --short"}
	if !reflect.DeepEqual(r.commands[2:], want) {
		t.Fatal(r.commands)
	}
	for _, path := range []string{"/etc/apt/keyrings/rctl-docker.asc", "/etc/apt/sources.list.d/rctl-docker.sources"} {
		info, err := os.Stat(d.path(path))
		if err != nil || info.Mode().Perm() != 0o644 {
			t.Fatalf("%s: %v", path, err)
		}
	}
}

func TestDockerDependenciesStopOnFailureOrCancellation(t *testing.T) {
	for _, cancelled := range []bool{false, true} {
		d, r := dependencyFixture(t)
		ctx, cancel := context.WithCancel(context.Background())
		if cancelled {
			r.cancel = cancel
		} else {
			r.fail = " update"
		}
		plan, err := d.Plan(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err := d.Install(ctx, plan, nil); err == nil {
			t.Fatal("expected failure")
		}
		cancel()
		if len(r.commands) != 1 {
			t.Fatal(r.commands)
		}
	}
}

func TestDockerRepositoryFailureDoesNotWriteSources(t *testing.T) {
	d, r := dependencyFixture(t)
	d.Fetch = func(context.Context, string) ([]byte, error) { return nil, errors.New("unsupported distribution") }
	plan, err := d.Plan(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := d.Install(context.Background(), plan, nil); err == nil {
		t.Fatal("expected failure")
	}
	if len(r.commands) != 0 {
		t.Fatal(r.commands)
	}
	if _, err := os.Stat(d.path("/etc/apt/keyrings")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("repository failure mutated sources")
	}
}

func TestDependencyFilesDoNotReplaceDifferentFilesOrSymlinks(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "source")
	if err := writeDependencyFile(path, []byte("original")); err != nil {
		t.Fatal(err)
	}
	if err := writeDependencyFile(path, []byte("original")); err != nil {
		t.Fatal(err)
	}
	if err := writeDependencyFile(path, []byte("replacement")); err == nil {
		t.Fatal("overwritten")
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if err := writeDependencyFile(link, []byte("original")); err == nil {
		t.Fatal("symlink followed")
	}
}
