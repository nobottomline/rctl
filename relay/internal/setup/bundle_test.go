package setup

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func TestGenerateSecretsAreIndependentAndShellSafe(t *testing.T) {
	raw := make([]byte, 256)
	for i := range raw {
		raw[i] = byte(i)
	}
	source := bytes.NewReader(raw)
	secrets, err := GenerateSecrets(source)
	if err != nil {
		t.Fatal(err)
	}
	if len(secrets.Admin) < 60 || len(secrets.Session) < 60 || len(secrets.TURN) != 64 {
		t.Fatalf("unexpected secret lengths: %#v", secrets)
	}
	if secrets.Admin == secrets.Session {
		t.Fatal("admin and session secrets must be independent")
	}
	for _, value := range []string{secrets.Admin, secrets.Session, secrets.TURN} {
		if strings.ContainsAny(value, "\r\n\x00 ='\"") {
			t.Fatal("generated secret is unsafe for a fixed env-file value")
		}
	}
}

func TestRenderDedicatedBundleIsPinnedAndDoesNotExposeRelayPort(t *testing.T) {
	cfg := validConfig()
	secrets := Secrets{Admin: strings.Repeat("a", 64), Session: strings.Repeat("b", 64), TURN: strings.Repeat("c", 64)}
	bundle, err := RenderDedicatedBundle(cfg, secrets)
	if err != nil {
		t.Fatal(err)
	}
	files := make(map[string]File)
	paths := DefaultPaths()
	for _, file := range bundle.Files {
		files[file.Path] = file
		if file.Secret && file.Mode != 0o600 {
			t.Errorf("secret file %s has mode %o", file.Path, file.Mode)
		}
	}
	var compose map[string]any
	if err := json.Unmarshal(files[paths.Compose].Content, &compose); err != nil {
		t.Fatal(err)
	}
	services := compose["services"].(map[string]any)
	relay := services["relay"].(map[string]any)
	if _, exists := relay["ports"]; exists {
		t.Fatal("relay service must not publish its HTTP port")
	}
	for name, raw := range services {
		service := raw.(map[string]any)
		image := service["image"].(string)
		if !strings.Contains(image, "@sha256:") {
			t.Errorf("service %s uses mutable image %q", name, image)
		}
		if _, ok := service["pids_limit"]; !ok {
			t.Errorf("service %s has no process limit", name)
		}
	}
	coturn := services["coturn"].(map[string]any)
	if got := coturn["cap_add"].([]any); len(got) != 1 || got[0] != "NET_BIND_SERVICE" {
		t.Fatalf("coturn capabilities=%v", got)
	}
	health := coturn["healthcheck"].(map[string]any)
	if !strings.Contains(fmt.Sprint(health["test"]), "turnutils_stunclient") {
		t.Fatal("coturn does not have a STUN health check")
	}
	env := string(files[paths.RelayEnv].Content)
	if !strings.Contains(env, "RCTL_RELAY_ENABLE_WEBRTC=1\n") || !strings.Contains(env, "RCTL_RELAY_TRUST_PROXY_HEADERS=1\n") {
		t.Fatal("relay production invariants are missing")
	}
	coturnConfig := string(files[paths.Coturn].Content)
	if !strings.Contains(coturnConfig, "static-auth-secret="+secrets.TURN) {
		t.Fatal("TURN and relay secrets do not match")
	}
	for _, obsolete := range []string{"no-cli", "no-dtls", "no-loopback-peers"} {
		if strings.Contains(coturnConfig, obsolete) {
			t.Errorf("coturn config contains obsolete option %q", obsolete)
		}
	}
	if !strings.Contains(coturnConfig, "denied-peer-ip=127.0.0.0-127.255.255.255") ||
		!strings.Contains(coturnConfig, "denied-peer-ip=::1") {
		t.Fatal("coturn config does not explicitly deny loopback peers")
	}
	if strings.Contains(string(files[paths.Caddyfile].Content), secrets.Admin) {
		t.Fatal("admin secret leaked into public proxy configuration")
	}
}

func TestRenderDedicatedBundleCanDisableTURN(t *testing.T) {
	cfg := validConfig()
	cfg.EnableTURN = false
	cfg.CoturnImage = ""
	cfg.TURNExternalIP = ""
	bundle, err := RenderDedicatedBundle(cfg, Secrets{Admin: strings.Repeat("a", 64), Session: strings.Repeat("b", 64), TURN: strings.Repeat("c", 64)})
	if err != nil {
		t.Fatal(err)
	}
	for _, file := range bundle.Files {
		if file.Path == DefaultPaths().Coturn {
			t.Fatal("TURN config rendered while disabled")
		}
	}
}

func TestRenderDedicatedBundleMountsPublicPackageReadOnly(t *testing.T) {
	cfg := validConfig()
	cfg.DevicePackages = true
	bundle, err := RenderDedicatedBundle(cfg, Secrets{Admin: strings.Repeat("a", 64), Session: strings.Repeat("b", 64), TURN: strings.Repeat("c", 64)})
	if err != nil {
		t.Fatal(err)
	}
	files := make(map[string]File)
	for _, file := range bundle.Files {
		files[file.Path] = file
	}
	paths := DefaultPaths()
	if !strings.Contains(string(files[paths.RelayEnv].Content), "RCTL_RELAY_PUBLIC_PACKAGE=/packages/rctl-public.deb\n") {
		t.Fatal("relay package path is missing from the environment")
	}
	var compose map[string]any
	if err := json.Unmarshal(files[paths.Compose].Content, &compose); err != nil {
		t.Fatal(err)
	}
	relay := compose["services"].(map[string]any)["relay"].(map[string]any)
	volumes := fmt.Sprint(relay["volumes"])
	if !strings.Contains(volumes, paths.PublicPackage+":/packages/rctl-public.deb:ro") {
		t.Fatalf("public package mount is missing or writable: %s", volumes)
	}
}
