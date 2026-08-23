package setup

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/mail"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
)

const (
	ConfigSchema        = 1
	ProfileContainer    = "container"
	ProfileNative       = "native"
	UpdateChannelStable = "stable"
	UpdateChannelCustom = "custom"
	UpdateChannelOff    = "off"
	maxConfigBytes      = 64 << 10
)

var (
	digestImagePattern         = regexp.MustCompile(`^[a-z0-9][a-z0-9._/-]*(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?@sha256:[a-f0-9]{64}$`)
	digestImageWithPortPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]*:([0-9]{1,5})/[a-z0-9][a-z0-9._/-]*(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?@sha256:[a-f0-9]{64}$`)
	semanticVersionPattern     = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)
)

type Config struct {
	Schema              int    `json:"schema"`
	PublicURL           string `json:"public_url"`
	Profile             string `json:"profile"`
	RelayImage          string `json:"relay_image,omitempty"`
	CaddyImage          string `json:"caddy_image,omitempty"`
	CoturnImage         string `json:"coturn_image,omitempty"`
	TURNExternalIP      string `json:"turn_external_ip,omitempty"`
	EnableTURN          bool   `json:"enable_turn"`
	ACMEEmail           string `json:"acme_email,omitempty"`
	Release             string `json:"release,omitempty"`
	DevicePackages      bool   `json:"device_packages,omitempty"`
	DeviceUpdateChannel string `json:"device_update_channel,omitempty"`
	UpdateManifestURL   string `json:"update_manifest_url,omitempty"`
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
	origin, err := ParsePublicOrigin(c.PublicURL)
	if err != nil {
		return err
	}
	if c.Profile != ProfileContainer && c.Profile != ProfileNative {
		return fmt.Errorf("unsupported deployment profile %q", c.Profile)
	}
	if c.Profile == ProfileContainer && !validDigestImage(c.RelayImage) {
		return errors.New("relay_image must be an OCI image pinned by sha256 digest")
	}
	if c.Profile == ProfileContainer && net.ParseIP(origin.Hostname()) != nil {
		return errors.New("container profile requires a DNS hostname; public IP certificates are not yet a supported profile")
	}
	if c.Profile == ProfileContainer && !validDigestImage(c.CaddyImage) {
		return errors.New("caddy_image must be an OCI image pinned by sha256 digest")
	}
	if c.Profile == ProfileContainer && c.EnableTURN && !validDigestImage(c.CoturnImage) {
		return errors.New("coturn_image must be an OCI image pinned by sha256 digest")
	}
	if c.EnableTURN {
		ip := net.ParseIP(c.TURNExternalIP)
		if ip == nil || ip.To4() == nil {
			return errors.New("turn_external_ip must be a public IPv4 address when TURN is enabled")
		}
		if !isPublicIP(ip) {
			return errors.New("turn_external_ip must not be private, loopback, link-local, or unspecified")
		}
	}
	if c.ACMEEmail != "" {
		address, err := mail.ParseAddress(c.ACMEEmail)
		if err != nil || address.Address != c.ACMEEmail || address.Name != "" || strings.ContainsAny(c.ACMEEmail, "\r\n\t ") {
			return errors.New("acme_email must be one plain email address")
		}
	}
	if err := validateUpdateManifestURL(c.UpdateManifestURL); err != nil {
		return err
	}
	switch c.DeviceUpdateChannel {
	case "":
		// Legacy schema-1 manifests predate named channels. They are normalized
		// transactionally by the first setup upgrade that knows about channels.
	case UpdateChannelStable, UpdateChannelCustom:
		if c.UpdateManifestURL == "" {
			return fmt.Errorf("device_update_channel %q requires update_manifest_url", c.DeviceUpdateChannel)
		}
	case UpdateChannelOff:
		if c.UpdateManifestURL != "" {
			return errors.New("device_update_channel off cannot have update_manifest_url")
		}
	default:
		return fmt.Errorf("unsupported device_update_channel %q", c.DeviceUpdateChannel)
	}
	return nil
}

func validateUpdateManifestURL(raw string) error {
	if raw == "" {
		return nil
	}
	if strings.ContainsAny(raw, "\r\n\t ") {
		return errors.New("update_manifest_url must not contain whitespace")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.RawPath != "" {
		return errors.New("update_manifest_url must be an absolute HTTPS URL without credentials, query, fragment, or encoded path")
	}
	if u.Path == "" || u.Path == "/" || strings.HasSuffix(u.Path, "/") {
		return errors.New("update_manifest_url must identify a manifest file")
	}
	if _, err := ParsePublicOrigin((&url.URL{Scheme: u.Scheme, Host: u.Host}).String()); err != nil {
		return fmt.Errorf("update_manifest_url origin: %w", err)
	}
	return nil
}

func validDigestImage(image string) bool {
	if digestImagePattern.MatchString(image) {
		return true
	}
	match := digestImageWithPortPattern.FindStringSubmatch(image)
	if match == nil {
		return false
	}
	port, err := strconv.Atoi(match[1])
	return err == nil && port > 0 && port <= 65535
}

func isPublicIP(ip net.IP) bool {
	if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() || ip.IsMulticast() {
		return false
	}
	for _, block := range []string{"100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4"} {
		_, network, _ := net.ParseCIDR(block)
		if network.Contains(ip) {
			return false
		}
	}
	return true
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
