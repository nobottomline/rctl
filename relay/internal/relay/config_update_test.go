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
