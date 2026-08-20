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
	if catalog.TargetVersion != "1.0.1" || len(catalog.Artifacts) != 2 || catalog.ProtocolMajor != 1 {
		t.Fatalf("unexpected catalog: %+v", catalog)
	}
}

func buildFixturePackage(t *testing.T, root, version string) string {
	t.Helper()
	directory := filepath.Join(root, "pkg-"+version)
	if err := os.MkdirAll(filepath.Join(directory, "DEBIAN"), 0o755); err != nil {
		t.Fatal(err)
	}
	control := "Package: com.greatlove.rctl\nVersion: " + version + "\nArchitecture: iphoneos-arm\nMaintainer: Test\nDescription: fixture\n"
	if err := os.WriteFile(filepath.Join(directory, "DEBIAN", "control"), []byte(control), 0o644); err != nil {
		t.Fatal(err)
	}
	result := filepath.Join(root, "rctl-"+version+".deb")
	if output, err := exec.Command("dpkg-deb", "--build", directory, result).CombinedOutput(); err != nil {
		t.Fatalf("dpkg-deb: %v: %s", err, output)
	}
	return result
}
