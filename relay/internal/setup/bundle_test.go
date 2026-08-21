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
	health := coturn["healthcheck"].(map[string]any)
	if !strings.Contains(fmt.Sprint(health["test"]), "turnutils_stunclient") {
		t.Fatal("coturn does not have a STUN health check")
	}
	env := string(files[paths.RelayEnv].Content)
	if !strings.Contains(env, "RCTL_RELAY_ENABLE_WEBRTC=1\n") || !strings.Contains(env, "RCTL_RELAY_TRUST_PROXY_HEADERS=1\n") {
		t.Fatal("relay production invariants are missing")
	}
	if !strings.Contains(string(files[paths.Coturn].Content), "static-auth-secret="+secrets.TURN) {
		t.Fatal("TURN and relay secrets do not match")
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
