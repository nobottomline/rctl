package setup

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func fixturePublicDevicePackage(t *testing.T, architecture, version string) string {
	t.Helper()
	if _, err := exec.LookPath("dpkg-deb"); err != nil {
		t.Skip("dpkg-deb is required for real package fixtures")
	}
	root := t.TempDir()
	data := filepath.Join(root, "data")
	if err := os.MkdirAll(filepath.Join(data, "DEBIAN"), 0o755); err != nil {
		t.Fatal(err)
	}
	control := "Package: com.greatlove.rctl\nVersion: " + version + "\nArchitecture: " + architecture + "\nMaintainer: Test\nDescription: fixture\n"
	if err := os.WriteFile(filepath.Join(data, "DEBIAN/control"), []byte(control), 0o644); err != nil {
		t.Fatal(err)
	}
	runtime := "usr/local/bin/rctld"
	if architecture == "iphoneos-arm64" {
		runtime = "var/jb/" + runtime
	}
	if err := os.MkdirAll(filepath.Dir(filepath.Join(data, runtime)), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(data, runtime), []byte("fixture"), 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(root, "package.deb")
	// Do not inherit a platform-specific compressor such as Ubuntu's zstd.
	if out, err := exec.Command("dpkg-deb", "-Zgzip", "--uniform-compression", "--build", data, target).CombinedOutput(); err != nil {
		t.Fatalf("build: %v %s", err, out)
	}
	return target
}

func TestDualPublicPackagesAndOwnership(t *testing.T) {
	cfg := validConfig()
	cfg.Release = "0.4.0"
	cfg.DevicePackages = true
	cfg.RootlessDevicePackages = true
	cfg.RootlessUpdateManifestURL = "https://releases.example.test/rootless.json"
	paths := PathsUnder(t.TempDir())
	rootful := fixturePublicDevicePackage(t, "iphoneos-arm", cfg.Release)
	rootless := fixturePublicDevicePackage(t, "iphoneos-arm64", cfg.Release)
	bundle, err := RenderDedicatedBundleAt(cfg, Secrets{Admin: strings.Repeat("a", 64), Session: strings.Repeat("s", 64), TURN: strings.Repeat("t", 64)}, paths)
	if err != nil {
		t.Fatal(err)
	}
	if err := appendPublicPackages(&bundle, cfg, paths, rootful, rootless); err != nil {
		t.Fatal(err)
	}
	manifest := manifestFor(cfg, bundle, cfg.Release, 1, 2)
	if err := validateOwnershipManifest(manifest, paths); err != nil {
		t.Fatal(err)
	}
	env := string(bundleFile(bundle, paths.RelayEnv).Content)
	if !strings.Contains(env, "RCTL_RELAY_ROOTLESS_PACKAGE=/packages/rctl-public-rootless.deb") || !strings.Contains(env, cfg.RootlessUpdateManifestURL) {
		t.Fatal("missing rootless runtime configuration")
	}
	if !strings.Contains(string(bundleFile(bundle, paths.Compose).Content), paths.RootlessPackage+":/packages/rctl-public-rootless.deb:ro") {
		t.Fatal("missing read-only rootless mount")
	}
	for _, sources := range [][2]string{{rootless, rootful}, {rootful, ""}} {
		candidate := Bundle{}
		if err := appendPublicPackages(&candidate, cfg, paths, sources[0], sources[1]); err == nil {
			t.Fatal("unsafe or missing package accepted")
		}
	}
	wrongVersion := fixturePublicDevicePackage(t, "iphoneos-arm64", "0.3.4")
	if err := appendPublicPackages(&Bundle{}, cfg, paths, rootful, wrongVersion); err == nil {
		t.Fatal("mismatched rootless version accepted")
	}
	cfg.RootlessDevicePackages = false
	if err := validateOwnershipManifest(OwnershipManifest{Version: manifest.Version, Config: cfg, CreatedAt: 1, UpdatedAt: 2, Files: manifest.Files}, paths); err == nil {
		t.Fatal("unowned rootless artifact accepted")
	}
}
