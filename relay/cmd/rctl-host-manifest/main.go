// rctl-host-manifest creates and verifies the purpose-bound host release feed.
package main

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/nobottomline/rctl/relay/internal/releasefeed"
)

func main() {
	dir := flag.String("dir", "", "directory with verified release artifacts")
	version := flag.String("version", "", "MAJOR.MINOR.PATCH")
	keyPath := flag.String("key", "", "release P-256 signing key")
	output := flag.String("output", "", "signed catalog output")
	verify := flag.String("verify", "", "verify a signed catalog and its artifacts instead of signing")
	flag.Parse()
	if err := run(*dir, *version, *keyPath, *output, *verify); err != nil {
		fmt.Fprintln(os.Stderr, "host manifest:", err)
		os.Exit(1)
	}
}

func run(dir, version, keyPath, output, verify string) error {
	if dir == "" || version == "" {
		return errors.New("-dir and -version are required")
	}
	if _, err := releasefeed.Compare(version, version); err != nil {
		return err
	}
	now := time.Now()
	c := releasefeed.Catalog{Purpose: releasefeed.Purpose, Channel: "stable", Version: version, IssuedAt: now.Unix(), ExpiresAt: now.Add(365 * 24 * time.Hour).Unix(), AgentProtocol: releasefeed.AgentProtocol, Artifacts: map[string]releasefeed.Artifact{}}
	for _, name := range releasefeed.Names(version) {
		p := filepath.Join(dir, name)
		info, err := os.Lstat(p)
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return errors.New("release artifacts must be regular files")
		}
		f, err := os.Open(p)
		if err != nil {
			return err
		}
		a, err := releasefeed.Inspect(f)
		f.Close()
		if err != nil {
			return err
		}
		c.Artifacts[name] = a
	}
	if verify != "" {
		raw, err := os.ReadFile(verify)
		if err != nil {
			return err
		}
		signed, err := releasefeed.Decode(raw, releasefeed.PublicKey(), now)
		if err != nil {
			return err
		}
		if signed.Version != version {
			return errors.New("signed host version mismatch")
		}
		for name, a := range c.Artifacts {
			if signed.Artifacts[name] != a {
				return errors.New("signed host artifact mismatch")
			}
		}
		return nil
	}
	if keyPath == "" || output == "" {
		return errors.New("-key and -output are required")
	}
	info, err := os.Lstat(keyPath)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		return errors.New("signing key must be a mode-0600 regular file")
	}
	raw, err := os.ReadFile(keyPath)
	if err != nil {
		return err
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return errors.New("invalid signing key")
	}
	key, err := x509.ParseECPrivateKey(block.Bytes)
	if err != nil {
		parsed, e := x509.ParsePKCS8PrivateKey(block.Bytes)
		if e != nil {
			return errors.New("invalid signing key")
		}
		var ok bool
		key, ok = parsed.(*ecdsa.PrivateKey)
		if !ok {
			return errors.New("ECDSA key required")
		}
	}
	if !key.PublicKey.Equal(releasefeed.PublicKey()) {
		return errors.New("signing key does not match release pin")
	}
	signed, err := releasefeed.Sign(c, key, now)
	if err != nil {
		return err
	}
	return os.WriteFile(output, append(signed, '\n'), 0o644)
}
