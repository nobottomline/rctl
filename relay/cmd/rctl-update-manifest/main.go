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

type artifactURLFlags map[string]string

func (values artifactURLFlags) String() string { return "VERSION=HTTPS_URL" }

func (values artifactURLFlags) Set(raw string) error {
	version, rawURL, ok := strings.Cut(raw, "=")
	if !ok || version == "" || rawURL == "" {
		return errors.New("artifact URL must be VERSION=HTTPS_URL")
	}
	if _, exists := values[version]; exists {
		return fmt.Errorf("duplicate artifact URL for version %q", version)
	}
	values[version] = rawURL
	return nil
}

func main() {
	keyPath := flag.String("key", "", "ECDSA P-256 private key PEM (required)")
	target := flag.String("target", "", "target Debian package version (required)")
	baseURL := flag.String("base-url", "", "public HTTPS directory containing artifacts")
	artifactURLs := artifactURLFlags{}
	flag.Var(artifactURLs, "artifact-url", "exact artifact URL as VERSION=HTTPS_URL (repeatable; replaces -base-url)")
	output := flag.String("output", "update-manifest.json", "output signed envelope")
	channel := flag.String("channel", "stable", "release channel")
	flag.Parse()
	if err := runWithURLs(*keyPath, *target, *baseURL, *output, *channel, flag.Args(), artifactURLs); err != nil {
		fmt.Fprintln(os.Stderr, "manifest:", err)
		os.Exit(1)
	}
}

func run(keyPath, target, baseURL, output, channel string, packagePaths []string) error {
	return runWithURLs(keyPath, target, baseURL, output, channel, packagePaths, nil)
}

func runWithURLs(keyPath, target, baseURL, output, channel string, packagePaths []string, artifactURLs map[string]string) error {
	if keyPath == "" || target == "" || len(packagePaths) < 2 {
		return errors.New("-key, -target, and at least current+target .deb files are required")
	}
	if (baseURL == "") == (len(artifactURLs) == 0) {
		return errors.New("use exactly one of -base-url or repeated -artifact-url")
	}
	var base *url.URL
	if baseURL != "" {
		parsed, err := url.Parse(baseURL)
		if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || parsed.RawPath != "" {
			return errors.New("base URL must be HTTPS without credentials, query, fragment, or encoded path")
		}
		base = parsed
	}
	key, err := readPrivateKey(keyPath)
	if err != nil {
		return err
	}

	result := payload{Schema: 1, Channel: channel, TargetVersion: target, ProtocolMajor: 1}
	versions := make(map[string]bool)
	for _, packagePath := range packagePaths {
		entry, err := inspectArtifact(base, artifactURLs, packagePath)
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
	for version := range artifactURLs {
		if !versions[version] {
			return fmt.Errorf("artifact URL was supplied for package version %q that is not present", version)
		}
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

func inspectArtifact(base *url.URL, artifactURLs map[string]string, name string) (artifact, error) {
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
	var artifactURL *url.URL
	if base != nil {
		resolved := *base
		resolved.Path = path.Join(strings.TrimSuffix(base.Path, "/"), filepath.Base(name))
		artifactURL = &resolved
	} else {
		rawURL, ok := artifactURLs[version]
		if !ok {
			return artifact{}, fmt.Errorf("artifact URL is missing for package version %q", version)
		}
		parsed, err := validateArtifactURL(rawURL, filepath.Base(name))
		if err != nil {
			return artifact{}, fmt.Errorf("artifact URL for version %s: %w", version, err)
		}
		artifactURL = parsed
	}
	return artifact{
		Version: version, URL: artifactURL.String(), SHA256: hex.EncodeToString(hash.Sum(nil)), Size: info.Size(),
	}, nil
}

func validateArtifactURL(raw, filename string) (*url.URL, error) {
	if strings.ContainsAny(raw, "\r\n\t ") {
		return nil, errors.New("URL must not contain whitespace")
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || parsed.RawPath != "" {
		return nil, errors.New("URL must be HTTPS without credentials, query, fragment, or encoded path")
	}
	if path.Base(parsed.Path) != filename {
		return nil, fmt.Errorf("URL path must end in %q", filename)
	}
	return parsed, nil
}
