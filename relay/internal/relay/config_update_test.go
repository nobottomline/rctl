package relay

import (
	"strings"
	"testing"
)

func TestUpdateTargetVersionConfiguration(t *testing.T) {
	t.Setenv("RCTL_RELAY_ADMIN_SECRET", strings.Repeat("a", 32))
	t.Setenv("RCTL_RELAY_SESSION_SECRET", strings.Repeat("s", 32))
	t.Setenv("RCTL_RELAY_ALLOW_INSECURE", "1")
	t.Setenv("RCTL_RELAY_UPDATE_MANIFEST_URL", "https://github.com/nobottomline/rctl/releases/latest/download/rctl-update-stable.json")
	t.Setenv("RCTL_RELAY_UPDATE_TARGET_VERSION", "0.3.1")
	cfg, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.UpdateTargetVersion != "0.3.1" {
		t.Fatalf("target version=%q", cfg.UpdateTargetVersion)
	}

	t.Setenv("RCTL_RELAY_UPDATE_TARGET_VERSION", "latest")
	if _, err := loadConfig(); err == nil || !strings.Contains(err.Error(), "MAJOR.MINOR.PATCH") {
		t.Fatalf("invalid target result=%v", err)
	}
}

func TestRootlessUpdateCatalogNeverFallsBack(t *testing.T) {
	cfg := config{UpdateManifestURL: "https://releases.example.test/rootful.json", UpdateTargetVersion: "0.4.0"}
	features := []string{"update.transactional", "update.transactional.rootless"}
	if url, _ := cfg.deviceUpdateCatalog(features); url != "" {
		t.Fatal("rootless fell back to rootful catalog")
	}
	cfg.RootlessUpdateManifestURL = "https://releases.example.test/rootless.json"
	cfg.RootlessUpdateTargetVersion = "0.4.1"
	if url, version := cfg.deviceUpdateCatalog(features); url != cfg.RootlessUpdateManifestURL || version != "0.4.1" {
		t.Fatal("wrong rootless catalog")
	}
	if url, version := cfg.deviceUpdateCatalog([]string{"update.transactional"}); url != cfg.UpdateManifestURL || version != "0.4.0" {
		t.Fatal("rootful catalog changed")
	}
}

func TestRootlessUpdateConfigurationRejectsUnsafeURLs(t *testing.T) {
	t.Setenv("RCTL_RELAY_ADMIN_SECRET", strings.Repeat("a", 32))
	t.Setenv("RCTL_RELAY_SESSION_SECRET", strings.Repeat("s", 32))
	t.Setenv("RCTL_RELAY_ALLOW_INSECURE", "1")
	for _, raw := range []string{"http://example.test/feed", "https://user:secret@example.test/feed", "https://example.test/", "https://example.test/feed?q=1"} {
		t.Setenv("RCTL_RELAY_ROOTLESS_UPDATE_MANIFEST_URL", raw)
		if _, err := loadConfig(); err == nil {
			t.Fatalf("accepted unsafe rootless URL %q", raw)
		}
	}
	t.Setenv("RCTL_RELAY_ROOTLESS_UPDATE_MANIFEST_URL", "https://releases.example.test/rootless.json")
	t.Setenv("RCTL_RELAY_ROOTLESS_UPDATE_TARGET_VERSION", "0.4.0")
	if _, err := loadConfig(); err != nil {
		t.Fatal(err)
	}
}
