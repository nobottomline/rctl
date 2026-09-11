package deb

import (
	"archive/tar"
	"strings"
	"testing"
)

func TestRootlessPersonalization(t *testing.T) {
	for _, format := range []string{"data.tar", "data.tar.gz", "data.tar.xz", "data.tar.lzma"} {
		t.Run(format, func(t *testing.T) {
			base := fixtureArchitecturePackage(t, format, false, "iphoneos-arm64")
			result, info, err := Personalize(base, Personalization{RelayURL: "wss://relay.example.test/device", Token: strings.Repeat("x", 40), DeviceName: "iPad"})
			if err != nil || info.Architecture != "iphoneos-arm64" {
				t.Fatalf("rootless personalization: %+v %v", info, err)
			}
			items, err := parseAR(result)
			if err != nil {
				t.Fatal(err)
			}
			_ = readTarFile(t, items[2].name, items[2].data, "var/jb/usr/local/bin/rctld")
			_ = readTarFile(t, items[2].name, items[2].data, relayConfigPath)
			reader, closeReader, err := compressedReader(items[2].name, items[2].data)
			if err != nil {
				t.Fatal(err)
			}
			defer closeReader()
			tr := tar.NewReader(reader)
			for {
				header, err := tr.Next()
				if err != nil {
					t.Fatal(err)
				}
				if header.Name == relayConfigPath {
					if header.Mode != 0600 {
						t.Fatal("enrollment must be private")
					}
					break
				}
			}
			if _, err := Inspect(result); err == nil {
				t.Fatal("accepted personalized base")
			}
		})
	}
}

func TestRootlessRejectsWrongRuntimeAndIdentity(t *testing.T) {
	for _, arch := range []string{"iphoneos-arm", "iphoneos-arm64"} {
		t.Run(arch, func(t *testing.T) {
			base := fixtureArchitecturePackage(t, "data.tar.gz", false, arch)
			items, _ := parseAR(base)
			other := "iphoneos-arm64"
			if arch == other {
				other = "iphoneos-arm"
			}
			items[1].data = fixtureControl(t, "Package: com.greatlove.rctl\nVersion: 1.2.3\nArchitecture: "+other+"\n")
			wrong, _ := writeAR(items)
			if _, err := Inspect(wrong); err == nil {
				t.Fatal("accepted architecture relabeling")
			}
			for _, name := range []string{relayConfigPath, "var/jb/" + relayConfigPath, "var/mobile"} {
				items, _ = parseAR(base)
				items[2].data, _ = appendTarFile(items[2].name, items[2].data, name, []byte("fixture"))
				wrong, _ = writeAR(items)
				if _, err := Inspect(wrong); err == nil {
					t.Fatalf("accepted unsafe entry %s", name)
				}
			}
		})
	}
}
