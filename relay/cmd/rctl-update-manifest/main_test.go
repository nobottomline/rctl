package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestSignedCatalogRoundTrip(t *testing.T) {
	directory := t.TempDir()
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalECPrivateKey(privateKey)
	if err != nil {
		t.Fatal(err)
	}
	keyPath := filepath.Join(directory, "release-key.pem")
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	current := buildFixturePackage(t, directory, "1.0.0")
	target := buildFixturePackage(t, directory, "1.0.1")
	output := filepath.Join(directory, "update.json")
	if err := run(keyPath, "1.0.1", "https://releases.example/rctl", output, "stable", []string{current, target}); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	var signed envelope
	if err := json.Unmarshal(raw, &signed); err != nil {
		t.Fatal(err)
	}
	payloadJSON, err := base64.StdEncoding.DecodeString(signed.Payload)
	if err != nil {
		t.Fatal(err)
	}
	signature, err := base64.StdEncoding.DecodeString(signed.Signature)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(payloadJSON)
	if !ecdsa.VerifyASN1(&privateKey.PublicKey, digest[:], signature) {
		t.Fatal("catalog signature did not verify")
	}
	var catalog payload
	if err := json.Unmarshal(payloadJSON, &catalog); err != nil {
		t.Fatal(err)
	}
	if catalog.Schema != 1 || catalog.Architecture != "" || catalog.TargetVersion != "1.0.1" || len(catalog.Artifacts) != 2 || catalog.ProtocolMajor != 1 {
		t.Fatalf("unexpected catalog: %+v", catalog)
	}
}

func TestCatalogSupportsImmutablePerReleaseURLs(t *testing.T) {
	directory := t.TempDir()
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalECPrivateKey(privateKey)
	keyPath := filepath.Join(directory, "release-key.pem")
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	current := buildFixturePackage(t, directory, "1.0.0")
	target := buildFixturePackage(t, directory, "1.0.1")
	urls := map[string]string{
		"1.0.0": "https://github.com/example/rctl/releases/download/v1.0.0/" + filepath.Base(current),
		"1.0.1": "https://github.com/example/rctl/releases/download/v1.0.1/" + filepath.Base(target),
	}
	output := filepath.Join(directory, "update.json")
	if err := runWithURLs(keyPath, "1.0.1", "", output, "stable", []string{current, target}, urls); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(output)
	var signed envelope
	if err := json.Unmarshal(raw, &signed); err != nil {
		t.Fatal(err)
	}
	payloadJSON, _ := base64.StdEncoding.DecodeString(signed.Payload)
	var catalog payload
	if err := json.Unmarshal(payloadJSON, &catalog); err != nil {
		t.Fatal(err)
	}
	for _, item := range catalog.Artifacts {
		if item.URL != urls[item.Version] {
			t.Fatalf("artifact %s URL=%q", item.Version, item.URL)
		}
	}

	bad := map[string]string{
		"1.0.0": urls["1.0.0"],
		"1.0.1": "https://github.com/example/rctl/releases/download/v1.0.1/wrong.deb",
	}
	if err := runWithURLs(keyPath, "1.0.1", "", output, "stable", []string{current, target}, bad); err == nil || !strings.Contains(err.Error(), "must end") {
		t.Fatalf("unsafe artifact URL result=%v", err)
	}
}

func TestRepositoryCatalogVerifierAcceptsSignedArtifacts(t *testing.T) {
	directory := t.TempDir()
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	privateDER, _ := x509.MarshalECPrivateKey(privateKey)
	keyPath := filepath.Join(directory, "release-key.pem")
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: privateDER}), 0o600); err != nil {
		t.Fatal(err)
	}
	publicDER, err := x509.MarshalPKIXPublicKey(&privateKey.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	publicPath := filepath.Join(directory, "public-key.pem")
	if err := os.WriteFile(publicPath, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: publicDER}), 0o644); err != nil {
		t.Fatal(err)
	}
	current := buildFixturePackage(t, directory, "1.0.0")
	target := buildFixturePackage(t, directory, "1.0.1")
	urls := map[string]string{
		"1.0.0": "https://github.com/example/rctl/releases/download/v1.0.0/" + filepath.Base(current),
		"1.0.1": "https://github.com/example/rctl/releases/download/v1.0.1/" + filepath.Base(target),
	}
	manifest := filepath.Join(directory, "rctl-update-stable.json")
	if err := runWithURLs(keyPath, "1.0.1", "", manifest, "stable", []string{current, target}, urls); err != nil {
		t.Fatal(err)
	}
	_, source, _, _ := runtime.Caller(0)
	script := filepath.Clean(filepath.Join(filepath.Dir(source), "..", "..", "..", "scripts", "verify_update_catalog.sh"))
	command := exec.Command(script, manifest, target)
	command.Env = append(os.Environ(), "RCTL_UPDATE_PUBLIC_KEY="+publicPath, "RCTL_UPDATE_CATALOG_ARTIFACTS_DIR="+directory)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("catalog verifier: %v\n%s", err, output)
	}
}

func buildFixturePackage(t *testing.T, root, version string) string {
	return buildArchitectureFixturePackage(t, root, version, "iphoneos-arm")
}

func TestRootlessCatalogIsArchitectureBound(t *testing.T) {
	directory := t.TempDir()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalECPrivateKey(key)
	keyPath := filepath.Join(directory, "key.pem")
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	publicDER, _ := x509.MarshalPKIXPublicKey(&key.PublicKey)
	publicPath := filepath.Join(directory, "public.pem")
	if err := os.WriteFile(publicPath, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: publicDER}), 0o644); err != nil {
		t.Fatal(err)
	}
	current := buildArchitectureFixturePackage(t, directory, "0.4.0~rc.1", "iphoneos-arm64")
	target := buildArchitectureFixturePackage(t, directory, "0.4.0~rc.2", "iphoneos-arm64")
	manifest := filepath.Join(directory, "rootless.json")
	if err := run(keyPath, "0.4.0~rc.2", "https://releases.example.test/rootless", manifest, "stable", []string{current, target}); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(manifest)
	var signed envelope
	if err := json.Unmarshal(raw, &signed); err != nil {
		t.Fatal(err)
	}
	decoded, _ := base64.StdEncoding.DecodeString(signed.Payload)
	var catalog payload
	if err := json.Unmarshal(decoded, &catalog); err != nil {
		t.Fatal(err)
	}
	if catalog.Schema != 2 || catalog.Architecture != "iphoneos-arm64" {
		t.Fatalf("wrong rootless schema: %+v", catalog)
	}
	_, source, _, _ := runtime.Caller(0)
	script := filepath.Clean(filepath.Join(filepath.Dir(source), "../../../scripts/verify_update_catalog.sh"))
	verify := func(target string) error {
		cmd := exec.Command(script, manifest, target)
		cmd.Env = append(os.Environ(), "RCTL_UPDATE_PUBLIC_KEY="+publicPath, "RCTL_UPDATE_CATALOG_ARTIFACTS_DIR="+directory)
		output, err := cmd.CombinedOutput()
		if err != nil {
			t.Logf("verifier: %s", output)
		}
		return err
	}
	if err := verify(target); err != nil {
		t.Fatal(err)
	}
	// The first public rootless release has no historical public rollback yet.
	if err := run(keyPath, "0.4.0~rc.2", "https://releases.example.test/rootless", manifest, "stable", []string{target}); err != nil {
		t.Fatal(err)
	}
	if err := verify(target); err != nil {
		t.Fatal(err)
	}
	wrong := buildFixturePackage(t, directory, "0.4.0~rc.2")
	if err := verify(wrong); err == nil {
		t.Fatal("cross-architecture target accepted")
	}
	if err := run(keyPath, "0.4.0~rc.2", "https://releases.example.test", manifest, "stable", []string{current, wrong}); err == nil {
		t.Fatal("mixed architecture catalog accepted")
	}
	personal := filepath.Join(directory, "pkg-0.4.0~rc.2-iphoneos-arm64", "var/mobile/Library/Preferences")
	if err := os.MkdirAll(personal, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(personal, "com.greatlove.rctl.relay.plist"), []byte("private fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command("dpkg-deb", "-Zgzip", "--uniform-compression", "--build", filepath.Join(directory, "pkg-0.4.0~rc.2-iphoneos-arm64"), target).CombinedOutput(); err != nil {
		t.Fatalf("build: %v %s", err, output)
	}
	if err := run(keyPath, "0.4.0~rc.2", "https://releases.example.test", manifest, "stable", []string{current, target}); err == nil {
		t.Fatal("personalized artifact accepted for public catalog")
	}
}

func buildArchitectureFixturePackage(t *testing.T, root, version, architecture string) string {
	t.Helper()
	directory := filepath.Join(root, "pkg-"+version+"-"+architecture)
	if err := os.MkdirAll(filepath.Join(directory, "DEBIAN"), 0o755); err != nil {
		t.Fatal(err)
	}
	control := "Package: com.greatlove.rctl\nVersion: " + version + "\nArchitecture: " + architecture + "\nMaintainer: Test\nDescription: fixture\n"
	if err := os.WriteFile(filepath.Join(directory, "DEBIAN", "control"), []byte(control), 0o644); err != nil {
		t.Fatal(err)
	}
	runtimePath := "usr/local/bin/rctld"
	if architecture == "iphoneos-arm64" {
		runtimePath = "var/jb/" + runtimePath
	}
	if err := os.MkdirAll(filepath.Dir(filepath.Join(directory, runtimePath)), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, runtimePath), []byte("fixture"), 0o755); err != nil {
		t.Fatal(err)
	}
	result := filepath.Join(root, "rctl_"+version+"_"+architecture+".deb")
	// Ubuntu defaults to zstd; fixtures must use the supported public DEB format.
	if output, err := exec.Command("dpkg-deb", "-Zgzip", "--uniform-compression", "--build", directory, result).CombinedOutput(); err != nil {
		t.Fatalf("dpkg-deb: %v: %s", err, output)
	}
	return result
}
