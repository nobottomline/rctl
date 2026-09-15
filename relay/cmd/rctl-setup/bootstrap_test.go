package main

import (
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/creack/pty"
)

func TestBootstrapSelectsLifecycleAndActivatesOnlyOnSuccess(t *testing.T) {
	_, sourceFile, _, _ := runtime.Caller(0)
	repositoryRoot := filepath.Clean(filepath.Join(filepath.Dir(sourceFile), "..", "..", ".."))
	raw, err := os.ReadFile(filepath.Join(repositoryRoot, "scripts", "install.sh"))
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	fakeBin := filepath.Join(root, "bin")
	assets := filepath.Join(root, "assets")
	destination := filepath.Join(root, "usr", "local", "bin", "rctl-setup")
	ownership := filepath.Join(root, "var", "lib", "rctl", "setup", "ownership.json")
	logPath := filepath.Join(root, "setup.log")
	for _, directory := range []string{fakeBin, assets} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	writeExecutable(t, filepath.Join(fakeBin, "id"), "#!/bin/sh\nprintf '0\\n'\n")
	writeExecutable(t, filepath.Join(fakeBin, "uname"), "#!/bin/sh\ncase \"$1\" in -s) echo Linux;; -m) echo x86_64;; *) exit 1;; esac\n")
	writeExecutable(t, filepath.Join(fakeBin, "gh"), "#!/bin/sh\nexit 1\n")
	writeExecutable(t, filepath.Join(fakeBin, "curl"), `#!/bin/sh
out=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && [ -n "$url" ] || exit 2
/bin/cp "$ASSET_DIR/${url##*/}" "$out"
`)
	setupAsset := filepath.Join(assets, "rctl-setup_linux_amd64")
	writeExecutable(t, setupAsset, `#!/bin/sh
printf '%s\n' "$*" >> "$SETUP_LOG"
[ "$1" != updates ] || exit 0
[ "${EXPECT_TTY:-0}" != 1 ] || {
  [ -t 0 ] || { echo 'setup stdin is not a terminal' >&2; exit 20; }
  IFS= read -r answer
  printf 'tty:%s\n' "$answer" >> "$SETUP_LOG"
}
[ "${FAIL_SETUP:-0}" != 1 ]
`)
	packageName := "rctl_1.2.3_iphoneos-arm.deb"
	packageAsset := filepath.Join(assets, packageName)
	if err := os.WriteFile(packageAsset, []byte("public package fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	checksums := fmt.Sprintf("%x  rctl-setup_linux_amd64\n%x  %s\n", sha256.Sum256(mustRead(t, setupAsset)), sha256.Sum256(mustRead(t, packageAsset)), packageName)
	legacyChecksums := checksums
	checksums += fmt.Sprintf("%x  rctl-host-stable.json\n", sha256.Sum256([]byte("host catalog fixture")))
	if err := os.WriteFile(filepath.Join(assets, "SHA256SUMS"), []byte(checksums), 0o600); err != nil {
		t.Fatal(err)
	}

	script := string(raw)
	script = strings.Replace(script, `PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"`, `PATH="`+fakeBin+`:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"`, 1)
	script = strings.Replace(script, `DESTINATION="/usr/local/bin/rctl-setup"`, `DESTINATION="`+destination+`"`, 1)
	script = strings.ReplaceAll(script, "/var/lib/rctl/setup/ownership.json", ownership)
	if !strings.Contains(script, destination) || !strings.Contains(script, ownership) {
		t.Fatal("bootstrap test substitutions did not apply")
	}
	scriptPath := filepath.Join(root, "install.sh")
	if err := os.WriteFile(scriptPath, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}

	runBootstrap(t, scriptPath, assets, logPath, false, "--yes")
	if string(mustRead(t, destination)) != string(mustRead(t, setupAsset)) {
		t.Fatal("fresh install did not activate the verified setup binary")
	}
	assertEnabledAfterLifecycle(t, logPath, "install --yes --public-package ")

	if err := os.MkdirAll(filepath.Dir(ownership), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ownership, []byte("owned"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(destination, []byte("previous setup binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	if runBootstrap(t, scriptPath, assets, logPath, true, "--yes") == nil {
		t.Fatal("failed upgrade unexpectedly succeeded")
	}
	if string(mustRead(t, destination)) != "previous setup binary" {
		t.Fatal("failed upgrade replaced the active setup binary")
	}
	assertLastLog(t, logPath, "upgrade --yes --public-package ")

	runBootstrap(t, scriptPath, assets, logPath, false, "--dry-run", "--yes")
	if string(mustRead(t, destination)) != "previous setup binary" {
		t.Fatal("dry run replaced the active setup binary")
	}
	assertLastLog(t, logPath, "upgrade --dry-run --yes --public-package ")

	runBootstrapOffline(t, scriptPath, assets, logPath, "--dry-run", "--yes")
	assertLastLog(t, logPath, "upgrade --dry-run --yes --public-package ")

	runBootstrapThroughPTY(t, scriptPath, assets, logPath)
	assertEnabledAfterLifecycle(t, logPath, "tty:install")

	beforeUnsafeLaunch := string(mustRead(t, logPath))
	unsafe := exec.Command("sh", scriptPath)
	unsafe.Env = append(os.Environ(), "SUDO_COMMAND=sh", "ASSET_DIR="+assets, "SETUP_LOG="+logPath)
	if output, err := unsafe.CombinedOutput(); err == nil || !strings.Contains(string(output), "download the script to a file") {
		t.Fatalf("piped sudo launch was not rejected: %v %s", err, output)
	}
	if string(mustRead(t, logPath)) != beforeUnsafeLaunch {
		t.Fatal("unsafe launch reached the wizard")
	}

	runBootstrap(t, scriptPath, assets, logPath, false, "--yes")
	if string(mustRead(t, destination)) != string(mustRead(t, setupAsset)) {
		t.Fatal("successful upgrade did not activate the verified setup binary")
	}
	if err := os.WriteFile(filepath.Join(assets, "SHA256SUMS"), []byte(legacyChecksums), 0o600); err != nil {
		t.Fatal(err)
	}
	runBootstrap(t, scriptPath, assets, logPath, false, "--yes")
	assertLastLog(t, logPath, "upgrade --yes --public-package ")
	if err := os.WriteFile(filepath.Join(assets, "SHA256SUMS"), []byte(checksums), 0o600); err != nil {
		t.Fatal(err)
	}

	assetsLink := filepath.Join(root, "assets-link")
	if err := os.Symlink(assets, assetsLink); err != nil {
		t.Fatal(err)
	}
	command := exec.Command("sh", scriptPath, "--dry-run", "--yes")
	command.Env = append(os.Environ(), "RCTL_ASSETS_DIR="+assetsLink, "SETUP_LOG="+logPath, "FAIL_SETUP=0")
	output, err := command.CombinedOutput()
	if err == nil || !strings.Contains(string(output), "must be a real directory, not a symlink") {
		t.Fatalf("symlinked offline asset directory: err=%v output=%s", err, output)
	}
	rootlessName := "rctl_1.2.3_iphoneos-arm64.deb"
	rootless := []byte("rootless public fixture")
	if err := os.WriteFile(filepath.Join(assets, rootlessName), rootless, 0o600); err != nil {
		t.Fatal(err)
	}
	checksums += fmt.Sprintf("%x  %s\n", sha256.Sum256(rootless), rootlessName)
	if err := os.WriteFile(filepath.Join(assets, "SHA256SUMS"), []byte(checksums), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := runBootstrap(t, scriptPath, assets, logPath, false, "--yes"); err != nil {
		t.Fatal(err)
	}
	assertEnabledAfterLifecycle(t, logPath, "upgrade --yes --rootless-public-package ")
	if err := os.WriteFile(filepath.Join(assets, rootlessName), []byte("corrupt"), 0o600); err != nil {
		t.Fatal(err)
	}
	before := string(mustRead(t, logPath))
	corrupt := exec.Command("sh", scriptPath, "--yes")
	corrupt.Env = append(os.Environ(), "ASSET_DIR="+assets, "SETUP_LOG="+logPath, "FAIL_SETUP=0")
	if out, err := corrupt.CombinedOutput(); err == nil || !strings.Contains(string(out), "checksum mismatch") {
		t.Fatalf("corrupt rootless package: %v %s", err, out)
	}
	if string(mustRead(t, logPath)) != before {
		t.Fatal("wizard ran before rootless checksum verification")
	}
}

func runBootstrapThroughPTY(t *testing.T, script, assets, log string) {
	t.Helper()
	command := exec.Command("sh", "-c", `cat "$BOOTSTRAP_SCRIPT" | sh`)
	command.Env = append(os.Environ(),
		"ASSET_DIR="+assets,
		"BOOTSTRAP_SCRIPT="+script,
		"SETUP_LOG="+log,
		"EXPECT_TTY=1",
		"FAIL_SETUP=0",
	)
	terminal, err := pty.Start(command)
	if err != nil {
		t.Fatal(err)
	}
	defer terminal.Close()
	if _, err := terminal.Write([]byte("install\n")); err != nil {
		t.Fatal(err)
	}
	output, readErr := io.ReadAll(terminal)
	waitErr := command.Wait()
	if waitErr != nil {
		t.Fatalf("piped bootstrap under PTY failed: %v (read=%v)\n%s", waitErr, readErr, output)
	}
}

func runBootstrapOffline(t *testing.T, script, assets, log string, args ...string) {
	t.Helper()
	command := exec.Command("sh", append([]string{script}, args...)...)
	command.Env = append(os.Environ(), "RCTL_ASSETS_DIR="+assets, "SETUP_LOG="+log, "FAIL_SETUP=0")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("offline bootstrap failed: %v\n%s", err, output)
	}
}

func runBootstrap(t *testing.T, script, assets, log string, fail bool, args ...string) error {
	t.Helper()
	command := exec.Command("sh", append([]string{script}, args...)...)
	failValue := "0"
	if fail {
		failValue = "1"
	}
	command.Env = append(os.Environ(), "ASSET_DIR="+assets, "SETUP_LOG="+log, "FAIL_SETUP="+failValue)
	output, err := command.CombinedOutput()
	if err != nil && !fail {
		t.Fatalf("bootstrap failed: %v\n%s", err, output)
	}
	return err
}

func writeExecutable(t *testing.T, name, content string) {
	t.Helper()
	if err := os.WriteFile(name, []byte(content), 0o700); err != nil {
		t.Fatal(err)
	}
}

func mustRead(t *testing.T, name string) []byte {
	t.Helper()
	raw, err := os.ReadFile(name)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func assertLastLog(t *testing.T, name, prefix string) {
	t.Helper()
	lines := strings.Split(strings.TrimSpace(string(mustRead(t, name))), "\n")
	if len(lines) == 0 || !strings.HasPrefix(lines[len(lines)-1], prefix) {
		t.Fatalf("last bootstrap invocation=%q, expected prefix %q", lines, prefix)
	}
}

func assertEnabledAfterLifecycle(t *testing.T, name, prefix string) {
	t.Helper()
	lines := strings.Split(strings.TrimSpace(string(mustRead(t, name))), "\n")
	if len(lines) < 2 || lines[len(lines)-1] != "updates enable" || !strings.HasPrefix(lines[len(lines)-2], prefix) {
		t.Fatalf("unexpected lifecycle/update-service order: %q", lines)
	}
}
