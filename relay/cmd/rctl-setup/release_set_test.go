package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// Package metadata and checksum assembly are real; executable format checks
// use a fixture so this test also runs on macOS without Linux emulation.
func TestReleaseSetArchitectureAdmission(t *testing.T) {
	if _, err := exec.LookPath("dpkg-deb"); err != nil {
		t.Skip("dpkg-deb is required")
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatal(err)
	}
	if exec.Command(bash, "-c", "type mapfile >/dev/null").Run() != nil {
		bash = "/opt/homebrew/bin/bash"
		if exec.Command(bash, "-c", "type mapfile >/dev/null").Run() != nil {
			t.Skip("Bash 4 or newer is required by release assembly")
		}
	}
	_, source, _, _ := runtime.Caller(0)
	script := filepath.Join(filepath.Dir(source), "../../../scripts/assemble_release_set.sh")
	for _, test := range []struct {
		name, architecture                 string
		rootless, catalog, required, valid bool
	}{
		{"legacy rootful", "", false, false, false, true},
		{"both architectures", "iphoneos-arm64", true, true, true, true},
		{"required rootless absent", "", false, false, true, false},
		{"missing rootless catalog", "iphoneos-arm64", true, false, true, false},
		{"wrong rootless architecture", "iphoneos-arm", true, true, true, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			assets, bin := filepath.Join(root, "release"), filepath.Join(root, "bin")
			for _, path := range []string{assets, bin} {
				if err := os.Mkdir(path, 0o700); err != nil {
					t.Fatal(err)
				}
			}
			writeExecutable(t, filepath.Join(bin, "file"), "#!/bin/sh\ncase \"$2\" in *_amd64) echo 'ELF 64-bit LSB x86-64';; *_arm64) echo 'ELF 64-bit LSB ARM aarch64';; *) exit 1;; esac\n")
			writeExecutable(t, filepath.Join(bin, "uname"), "#!/bin/sh\necho Darwin\n")
			for _, name := range []string{"install.sh", "rctl-relay_linux_amd64", "rctl-relay_linux_arm64", "rctl-setup_linux_amd64", "rctl-setup_linux_arm64"} {
				writeExecutable(t, filepath.Join(assets, name), "#!/bin/sh\nexit 1\n")
			}
			build := func(filename, architecture string) {
				data := filepath.Join(root, architecture+"-"+filename)
				if err := os.MkdirAll(filepath.Join(data, "DEBIAN"), 0o755); err != nil {
					t.Fatal(err)
				}
				control := "Package: com.greatlove.rctl\nVersion: 0.4.0\nArchitecture: " + architecture + "\nMaintainer: Test\nDescription: fixture\n"
				if err := os.WriteFile(filepath.Join(data, "DEBIAN/control"), []byte(control), 0o600); err != nil {
					t.Fatal(err)
				}
				if out, err := exec.Command("dpkg-deb", "-Zgzip", "--uniform-compression", "--build", data, filepath.Join(assets, filename)).CombinedOutput(); err != nil {
					t.Fatalf("%v: %s", err, out)
				}
			}
			build("rctl_0.4.0_iphoneos-arm.deb", "iphoneos-arm")
			if test.rootless {
				build("rctl_0.4.0_iphoneos-arm64.deb", test.architecture)
			}
			if test.catalog {
				if err := os.WriteFile(filepath.Join(assets, "rctl-update-rootless-stable.json"), []byte("catalog fixture verified separately"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			command := exec.Command(bash, script, assets, "0.4.0", strings.Repeat("a", 40))
			command.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"), "RCTL_REQUIRE_ROOTLESS=0", "RCTL_REQUIRE_UPDATE_CATALOG=0", "RCTL_REQUIRE_EXECUTABLE_CHECK=0")
			if test.required {
				command.Env = append(command.Env, "RCTL_REQUIRE_ROOTLESS=1")
			}
			out, err := command.CombinedOutput()
			if (err == nil) != test.valid {
				t.Fatalf("valid=%v, error=%v, output=%s", test.valid, err, out)
			}
			if test.valid {
				sums := string(mustRead(t, filepath.Join(assets, "SHA256SUMS")))
				if strings.Contains(sums, "iphoneos-arm64.deb") != test.rootless {
					t.Fatal("checksum lane mismatch")
				}
			} else if _, err := os.Stat(filepath.Join(assets, "SHA256SUMS")); !os.IsNotExist(err) {
				t.Fatal("rejected release emitted checksums")
			}
		})
	}
}
