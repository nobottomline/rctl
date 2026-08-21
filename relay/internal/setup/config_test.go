package setup

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	testImage  = "ghcr.io/nobottomline/rctl-relay@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	testCaddy  = "docker.io/library/caddy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	testCoturn = "docker.io/coturn/coturn@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
)

func validConfig() Config {
	return Config{Schema: ConfigSchema, PublicURL: "https://rctl.example.com", Profile: ProfileContainer, RelayImage: testImage, CaddyImage: testCaddy, CoturnImage: testCoturn, TURNExternalIP: "8.8.8.8", EnableTURN: true}
}

func TestConfigValidate(t *testing.T) {
	if err := validConfig().Validate(); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name   string
		mutate func(*Config)
	}{
		{"http", func(c *Config) { c.PublicURL = "http://rctl.example.com" }},
		{"path", func(c *Config) { c.PublicURL = "https://rctl.example.com/admin" }},
		{"ip origin", func(c *Config) { c.PublicURL = "https://8.8.8.8" }},
		{"credentials", func(c *Config) { c.PublicURL = "https://user:pass@rctl.example.com" }},
		{"unicode host", func(c *Config) { c.PublicURL = "https://rctl.example.\u0440\u0444" }},
		{"mutable image", func(c *Config) { c.RelayImage = "ghcr.io/nobottomline/rctl-relay:latest" }},
		{"bad digest", func(c *Config) { c.RelayImage = "ghcr.io/nobottomline/rctl-relay@sha256:abc" }},
		{"mutable caddy", func(c *Config) { c.CaddyImage = "caddy:latest" }},
		{"private turn ip", func(c *Config) { c.TURNExternalIP = "192.168.1.10" }},
		{"reserved turn ip", func(c *Config) { c.TURNExternalIP = "203.0.113.10" }},
		{"caddy injection", func(c *Config) { c.ACMEEmail = "admin@example.com }" }},
		{"http update manifest", func(c *Config) { c.UpdateManifestURL = "http://releases.example.com/catalog.json" }},
		{"update manifest credentials", func(c *Config) { c.UpdateManifestURL = "https://user:pass@releases.example.com/catalog.json" }},
		{"update manifest query", func(c *Config) { c.UpdateManifestURL = "https://releases.example.com/catalog.json?channel=stable" }},
		{"update manifest directory", func(c *Config) { c.UpdateManifestURL = "https://releases.example.com/catalog/" }},
		{"unknown profile", func(c *Config) { c.Profile = "magic" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := validConfig()
			tc.mutate(&cfg)
			if err := cfg.Validate(); err == nil {
				t.Fatal("expected validation failure")
			}
		})
	}
}

func TestConfigAcceptsSignedUpdateManifestURL(t *testing.T) {
	cfg := validConfig()
	cfg.UpdateManifestURL = "https://github.com/nobottomline/rctl/releases/latest/download/rctl-update-stable.json"
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestDigestImageAcceptsRegistryPort(t *testing.T) {
	digest := strings.Repeat("a", 64)
	for _, image := range []string{
		"127.0.0.1:5000/rctl-relay@sha256:" + digest,
		"registry.example.com:443/team/rctl-relay:v1@sha256:" + digest,
	} {
		if !validDigestImage(image) {
			t.Fatalf("valid image was rejected: %s", image)
		}
	}
	for _, image := range []string{
		"127.0.0.1:0/rctl-relay@sha256:" + digest,
		"127.0.0.1:65536/rctl-relay@sha256:" + digest,
		"127.0.0.1:5000/rctl-relay:latest",
		"127.0.0.1:5000//rctl-relay@sha256:" + digest,
	} {
		if validDigestImage(image) {
			t.Fatalf("invalid image was accepted: %s", image)
		}
	}
}

func TestLoadConfigRejectsLoosePermissionsAndUnknownFields(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "setup.json")
	raw := `{"schema":1,"public_url":"https://rctl.example.com","profile":"container","relay_image":"` + testImage + `","caddy_image":"` + testCaddy + `","coturn_image":"` + testCoturn + `","turn_external_ip":"8.8.8.8","enable_turn":true}`
	if err := os.WriteFile(path, []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(path); err == nil || !strings.Contains(err.Error(), "group/others") {
		t.Fatalf("unexpected permission result: %v", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(path); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(strings.TrimSuffix(raw, "}")+`,"secret":"leak"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(path); err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("unexpected unknown-field result: %v", err)
	}
	if err := os.WriteFile(path, []byte(raw+` {"schema":1}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(path); err == nil || !strings.Contains(err.Error(), "trailing JSON") {
		t.Fatalf("unexpected trailing-data result: %v", err)
	}
}

func TestLoadConfigRejectsSymlinkAndOversizedFile(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target.json")
	link := filepath.Join(dir, "link.json")
	if err := os.WriteFile(target, []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(link); err == nil || !strings.Contains(err.Error(), "regular file") {
		t.Fatalf("unexpected symlink result: %v", err)
	}
	large := filepath.Join(dir, "large.json")
	if err := os.WriteFile(large, make([]byte, maxConfigBytes+1), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(large); err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("unexpected oversized result: %v", err)
	}
}
