package main

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
)

type artifact struct {
	Version string `json:"version"`
	URL     string `json:"url"`
	SHA256  string `json:"sha256"`
	Size    int64  `json:"size"`
}

type payload struct {
	Schema        int        `json:"schema"`
	Channel       string     `json:"channel"`
	TargetVersion string     `json:"target_version"`
	ProtocolMajor int        `json:"protocol_major"`
	Artifacts     []artifact `json:"artifacts"`
}

type envelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

func main() {
	keyPath := flag.String("key", "", "ECDSA P-256 private key PEM (required)")
	target := flag.String("target", "", "target Debian package version (required)")
	baseURL := flag.String("base-url", "", "public HTTPS directory containing artifacts")
	output := flag.String("output", "update-manifest.json", "output signed envelope")
	channel := flag.String("channel", "stable", "release channel")
	flag.Parse()
	if err := run(*keyPath, *target, *baseURL, *output, *channel, flag.Args()); err != nil {
		fmt.Fprintln(os.Stderr, "manifest:", err)
		os.Exit(1)
	}
}

func run(keyPath, target, baseURL, output, channel string, packagePaths []string) error {
	if keyPath == "" || target == "" || baseURL == "" || len(packagePaths) < 2 {
		return errors.New("-key, -target, -base-url, and at least current+target .deb files are required")
	}
	base, err := url.Parse(baseURL)
	if err != nil || base.Scheme != "https" || base.Host == "" || base.User != nil || base.Fragment != "" {
		return errors.New("base URL must be HTTPS without credentials or fragment")
	}
	key, err := readPrivateKey(keyPath)
	if err != nil {
		return err
	}

	result := payload{Schema: 1, Channel: channel, TargetVersion: target, ProtocolMajor: 1}
	versions := make(map[string]bool)
	for _, packagePath := range packagePaths {
		entry, err := inspectArtifact(base, packagePath)
		if err != nil {
			return err
		}
		if versions[entry.Version] {
			return fmt.Errorf("duplicate package version %q", entry.Version)
		}
		versions[entry.Version] = true
		result.Artifacts = append(result.Artifacts, entry)
	}
	if !versions[target] {
		return fmt.Errorf("target version %q is not among artifacts", target)
	}
	payloadJSON, err := json.Marshal(result)
	if err != nil {
		return err
	}
	digest := sha256.Sum256(payloadJSON)
	signature, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		return err
	}
	envelopeJSON, err := json.MarshalIndent(envelope{
		Payload:   base64.StdEncoding.EncodeToString(payloadJSON),
		Signature: base64.StdEncoding.EncodeToString(signature),
	}, "", "  ")
	if err != nil {
		return err
	}
	envelopeJSON = append(envelopeJSON, '\n')
	temporary := output + ".tmp"
	if err := os.WriteFile(temporary, envelopeJSON, 0o644); err != nil {
		return err
	}
	return os.Rename(temporary, output)
}

func readPrivateKey(name string) (*ecdsa.PrivateKey, error) {
	raw, err := os.ReadFile(name)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("private key is not PEM")
	}
	if key, err := x509.ParseECPrivateKey(block.Bytes); err == nil {
		if key.Curve.Params().Name != "P-256" {
			return nil, errors.New("private key must use P-256")
		}
		return key, nil
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("private key must be SEC1 or PKCS#8 ECDSA")
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("private key is not ECDSA")
	}
	if key.Curve.Params().Name != "P-256" {
		return nil, errors.New("private key must use P-256")
	}
	return key, nil
}

func inspectArtifact(base *url.URL, name string) (artifact, error) {
	file, err := os.Open(name)
	if err != nil {
		return artifact{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return artifact{}, err
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return artifact{}, err
	}
	command := exec.Command("dpkg-deb", "-f", name)
	metadata, err := command.Output()
	if err != nil {
		return artifact{}, fmt.Errorf("inspect %s: %w", name, err)
	}
	var packageID, version string
	for _, line := range strings.Split(string(metadata), "\n") {
		key, value, ok := strings.Cut(line, ": ")
		if !ok {
			continue
		}
		switch key {
		case "Package":
			packageID = value
		case "Version":
			version = value
		}
	}
	if packageID != "com.greatlove.rctl" || version == "" {
		return artifact{}, fmt.Errorf("%s is not an rctl package", name)
	}
	artifactURL := *base
	artifactURL.Path = path.Join(strings.TrimSuffix(base.Path, "/"), filepath.Base(name))
	return artifact{
		Version: version, URL: artifactURL.String(), SHA256: hex.EncodeToString(hash.Sum(nil)), Size: info.Size(),
	}, nil
}
