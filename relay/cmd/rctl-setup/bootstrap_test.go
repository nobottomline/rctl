package main

import (
	"crypto/sha256"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
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
[ "${FAIL_SETUP:-0}" != 1 ]
`)
	packageName := "rctl_1.2.3_iphoneos-arm.deb"
	packageAsset := filepath.Join(assets, packageName)
	if err := os.WriteFile(packageAsset, []byte("public package fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	checksums := fmt.Sprintf("%x  rctl-setup_linux_amd64\n%x  %s\n", sha256.Sum256(mustRead(t, setupAsset)), sha256.Sum256(mustRead(t, packageAsset)), packageName)
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
	assertLastLog(t, logPath, "install --yes --public-package ")

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

	runBootstrap(t, scriptPath, assets, logPath, false, "--yes")
	if string(mustRead(t, destination)) != string(mustRead(t, setupAsset)) {
		t.Fatal("successful upgrade did not activate the verified setup binary")
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
