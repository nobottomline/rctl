package deb

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ulikunitz/xz"
	"github.com/ulikunitz/xz/lzma"
)

func TestPersonalizeSupportedFormats(t *testing.T) {
	for _, format := range []string{"data.tar", "data.tar.gz", "data.tar.lzma", "data.tar.xz"} {
		t.Run(format, func(t *testing.T) {
			base := fixturePackage(t, format, false)
			result, info, err := Personalize(base, Personalization{
				RelayURL:   "wss://relay.example.test/device",
				Token:      "enroll_test_abcdefghijklmnopqrstuvwxyz0123456789.ABCDEF",
				DeviceName: "Family & Travel <iPad>",
			})
			if err != nil {
				t.Fatal(err)
			}
			if info.Package != "com.greatlove.rctl" || info.Version != "1.2.3" || info.DataFormat != format {
				t.Fatalf("unexpected package info: %+v", info)
			}
			items, err := parseAR(result)
			if err != nil {
				t.Fatal(err)
			}
			found, err := tarContains(items[2].name, items[2].data, relayConfigPath)
			if err != nil || !found {
				t.Fatalf("relay config missing: found=%t err=%v", found, err)
			}
			plist := readTarFile(t, items[2].name, items[2].data, relayConfigPath)
			for _, wanted := range []string{"Family &amp; Travel &lt;iPad&gt;", "wss://relay.example.test/device", "enroll_test_abcdefghijklmnopqrstuvwxyz0123456789.ABCDEF"} {
				if !bytes.Contains(plist, []byte(wanted)) {
					t.Fatalf("plist does not contain %q:\n%s", wanted, plist)
				}
			}
			if _, _, err := Personalize(result, Personalization{RelayURL: "wss://relay.example.test/device", Token: strings.Repeat("x", 40), DeviceName: "iPad"}); err == nil || !strings.Contains(err.Error(), "already contains") {
				t.Fatalf("personalized package was accepted again: %v", err)
			}
		})
	}
}

func TestPersonalizeRejectsWrongPackageAndInputs(t *testing.T) {
	base := fixturePackage(t, "data.tar.lzma", false)
	cases := []Personalization{
		{RelayURL: "http://relay.example.test/device", Token: strings.Repeat("x", 40), DeviceName: "iPad"},
		{RelayURL: "wss://relay.example.test/wrong", Token: strings.Repeat("x", 40), DeviceName: "iPad"},
		{RelayURL: "wss://relay.example.test/device", Token: "short", DeviceName: "iPad"},
		{RelayURL: "wss://relay.example.test/device", Token: strings.Repeat("x", 40), DeviceName: "\n"},
	}
	for _, values := range cases {
		if _, _, err := Personalize(base, values); err == nil {
			t.Fatalf("accepted invalid personalization: %+v", values)
		}
	}

	items, err := parseAR(base)
	if err != nil {
		t.Fatal(err)
	}
	items[1].data = fixtureControl(t, "Package: attacker\nVersion: 1.2.3\nArchitecture: iphoneos-arm\n")
	wrong, err := writeAR(items)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Inspect(wrong); err == nil || !strings.Contains(err.Error(), "not a supported") {
		t.Fatalf("wrong package accepted: %v", err)
	}
}

func TestPersonalizeRejectsUnsafeArchivePath(t *testing.T) {
	base := fixturePackage(t, "data.tar.gz", true)
	if _, err := Inspect(base); err == nil || !strings.Contains(err.Error(), "unsafe archive path") {
		t.Fatalf("unsafe archive accepted: %v", err)
	}
}

func TestCleanTarNameAllowsOnlyLiteralRoot(t *testing.T) {
	for _, safe := range []string{".", "./"} {
		if got, err := cleanTarName(safe); err != nil || got != "." {
			t.Fatalf("literal root %q: got=%q err=%v", safe, got, err)
		}
	}
	for _, unsafe := range []string{"../x", "/x", "a/../../x", "a/..", "./../x"} {
		if _, err := cleanTarName(unsafe); err == nil {
			t.Fatalf("unsafe path %q was accepted", unsafe)
		}
	}
}

func TestPersonalizedPackageAcceptedByDpkg(t *testing.T) {
	dpkg, err := exec.LookPath("dpkg-deb")
	if err != nil {
		t.Skip("dpkg-deb is not installed")
	}
	result, _, err := Personalize(fixturePackage(t, "data.tar.lzma", false), Personalization{
		RelayURL: "wss://relay.example.test/device", Token: strings.Repeat("x", 48), DeviceName: "iPad",
	})
	if err != nil {
		t.Fatal(err)
	}
	name := filepath.Join(t.TempDir(), "personalized.deb")
	if err := os.WriteFile(name, result, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"--info", name}, {"--contents", name}} {
		if output, err := exec.Command(dpkg, args...).CombinedOutput(); err != nil {
			t.Fatalf("dpkg-deb %v: %v\n%s", args, err, output)
		}
	}
}

func TestExternalPublicPackage(t *testing.T) {
	name := os.Getenv("RCTL_TEST_PUBLIC_DEB")
	if name == "" {
		t.Skip("set RCTL_TEST_PUBLIC_DEB for release-package qualification")
	}
	base, err := os.ReadFile(name)
	if err != nil {
		t.Fatal(err)
	}
	result, info, err := Personalize(base, Personalization{
		RelayURL: "wss://relay.example.test/device", Token: strings.Repeat("x", 48), DeviceName: "Qualification iPad",
	})
	if err != nil {
		t.Fatal(err)
	}
	if info.Package != "com.greatlove.rctl" || info.Architecture != "iphoneos-arm" {
		t.Fatalf("unexpected package info: %+v", info)
	}
	if dpkg, err := exec.LookPath("dpkg-deb"); err == nil {
		output := filepath.Join(t.TempDir(), "personalized.deb")
		if err := os.WriteFile(output, result, 0o600); err != nil {
			t.Fatal(err)
		}
		if details, err := exec.Command(dpkg, "--contents", output).CombinedOutput(); err != nil || !bytes.Contains(details, []byte(relayConfigPath)) {
			t.Fatalf("dpkg qualification failed: %v\n%s", err, details)
		}
	}
}

func fixturePackage(t *testing.T, format string, unsafe bool) []byte {
	t.Helper()
	control := fixtureControl(t, "Package: com.greatlove.rctl\nVersion: 1.2.3\nArchitecture: iphoneos-arm\n")
	var tarData bytes.Buffer
	tw := tar.NewWriter(&tarData)
	name := "usr/local/bin/rctld"
	if unsafe {
		name = "../../escape"
	}
	payload := []byte("fixture")
	if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Typeflag: tar.TypeReg, Size: int64(len(payload))}); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write(payload); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	data := compressFixture(t, format, tarData.Bytes())
	result, err := writeAR([]member{
		fixtureMember("debian-binary", []byte("2.0\n")),
		fixtureMember("control.tar.gz", control),
		fixtureMember(format, data),
	})
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func fixtureControl(t *testing.T, content string) []byte {
	t.Helper()
	var tarData bytes.Buffer
	tw := tar.NewWriter(&tarData)
	if err := tw.WriteHeader(&tar.Header{Name: "./control", Mode: 0o644, Typeflag: tar.TypeReg, Size: int64(len(content))}); err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(tw, content); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	var compressed bytes.Buffer
	zw := gzip.NewWriter(&compressed)
	if _, err := zw.Write(tarData.Bytes()); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return compressed.Bytes()
}

func compressFixture(t *testing.T, format string, raw []byte) []byte {
	t.Helper()
	var out bytes.Buffer
	var writer io.WriteCloser
	var err error
	switch format {
	case "data.tar":
		return raw
	case "data.tar.gz":
		writer = gzip.NewWriter(&out)
	case "data.tar.lzma":
		writer, err = lzma.NewWriter(&out)
	case "data.tar.xz":
		writer, err = xz.NewWriter(&out)
	default:
		t.Fatalf("unsupported fixture format %s", format)
	}
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(raw); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func fixtureMember(name string, data []byte) member {
	var header [60]byte
	copy(header[0:16], fmt.Sprintf("%-16s", name+"/"))
	copy(header[16:28], fmt.Sprintf("%-12d", 0))
	copy(header[28:34], fmt.Sprintf("%-6d", 0))
	copy(header[34:40], fmt.Sprintf("%-6d", 0))
	copy(header[40:48], fmt.Sprintf("%-8s", "100644"))
	copy(header[48:58], fmt.Sprintf("%-10d", len(data)))
	copy(header[58:60], "`\n")
	return member{header: header, name: name, data: data}
}

func readTarFile(t *testing.T, name string, data []byte, wanted string) []byte {
	t.Helper()
	reader, closeReader, err := compressedReader(name, data)
	if err != nil {
		t.Fatal(err)
	}
	defer closeReader()
	tr := tar.NewReader(reader)
	for {
		header, err := tr.Next()
		if errors.Is(err, io.EOF) {
			t.Fatalf("%s not found", wanted)
		}
		if err != nil {
			t.Fatal(err)
		}
		clean, err := cleanTarName(header.Name)
		if err != nil {
			t.Fatal(err)
		}
		if clean == wanted {
			content, err := io.ReadAll(tr)
			if err != nil {
				t.Fatal(err)
			}
			return content
		}
	}
}
