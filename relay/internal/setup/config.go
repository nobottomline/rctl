package setup

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"regexp"
	"strings"
)

const (
	ConfigSchema     = 1
	ProfileContainer = "container"
	ProfileNative    = "native"
	maxConfigBytes   = 64 << 10
)

var digestImagePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._/-]*(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?@sha256:[a-f0-9]{64}$`)

type Config struct {
	Schema      int    `json:"schema"`
	PublicURL   string `json:"public_url"`
	Profile     string `json:"profile"`
	RelayImage  string `json:"relay_image,omitempty"`
	EnableTURN  bool   `json:"enable_turn"`
	ACMEEmail   string `json:"acme_email,omitempty"`
	Release     string `json:"release,omitempty"`
	ImageDigest string `json:"image_digest,omitempty"`
}

func DefaultConfig() Config {
	return Config{Schema: ConfigSchema, Profile: ProfileContainer, EnableTURN: true}
}

func LoadConfig(path string) (Config, error) {
	cfg := DefaultConfig()
	info, err := os.Lstat(path)
	if err != nil {
		return cfg, fmt.Errorf("stat config: %w", err)
	}
	if !info.Mode().IsRegular() {
		return cfg, errors.New("config must be a regular file, not a symlink or device")
	}
	if info.Size() > maxConfigBytes {
		return cfg, fmt.Errorf("config exceeds %d bytes", maxConfigBytes)
	}
	if info.Mode().Perm()&0o077 != 0 {
		return cfg, errors.New("config must not be readable or writable by group/others")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return cfg, fmt.Errorf("read config: %w", err)
	}
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return cfg, fmt.Errorf("decode config: %w", err)
	}
	var trailing any
	if err := dec.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return cfg, errors.New("config contains trailing JSON values")
		}
		return cfg, fmt.Errorf("decode trailing config data: %w", err)
	}
	return cfg, cfg.Validate()
}

func (c Config) Validate() error {
	if c.Schema != ConfigSchema {
		return fmt.Errorf("unsupported config schema %d", c.Schema)
	}
	if _, err := ParsePublicOrigin(c.PublicURL); err != nil {
		return err
	}
	if c.Profile != ProfileContainer && c.Profile != ProfileNative {
		return fmt.Errorf("unsupported deployment profile %q", c.Profile)
	}
	if c.Profile == ProfileContainer && !digestImagePattern.MatchString(c.RelayImage) {
		return errors.New("relay_image must be an OCI image pinned by sha256 digest")
	}
	if strings.ContainsAny(c.ACMEEmail, "\r\n") {
		return errors.New("acme_email contains a newline")
	}
	return nil
}

func ParsePublicOrigin(raw string) (*url.URL, error) {
	if raw == "" {
		return nil, errors.New("public_url is required")
	}
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("parse public_url: %w", err)
	}
	if u.Scheme != "https" || u.Host == "" {
		return nil, errors.New("public_url must be an absolute https origin")
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return nil, errors.New("public_url must not contain credentials, path, query, or fragment")
	}
	host := u.Hostname()
	if host == "" || strings.ContainsAny(host, " \t\r\n") {
		return nil, errors.New("public_url has an invalid host")
	}
	if net.ParseIP(host) == nil {
		if len(host) > 253 || strings.HasPrefix(host, ".") || strings.HasSuffix(host, ".") {
			return nil, errors.New("public_url has an invalid DNS name")
		}
		for _, label := range strings.Split(host, ".") {
			if label == "" || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
				return nil, errors.New("public_url has an invalid DNS label")
			}
			for _, r := range label {
				if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-') {
					return nil, errors.New("public_url DNS names must be ASCII letters, digits, dots, and hyphens")
				}
			}
		}
	}
	u.Path = ""
	return u, nil
}
