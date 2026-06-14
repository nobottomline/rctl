package relay

import (
	"strings"
	"testing"
)

func TestAdminUIIncludesControlPageAction(t *testing.T) {
	for _, want := range []string{
		`const controlURL = "/control/devices/" + encodeURIComponent(device.id);`,
		`<a class="buttonLink" href="`,
		`Open</a>`,
		`device.online ?`,
		`offline</span>`,
	} {
		if !strings.Contains(adminJS, want) {
			t.Fatalf("adminJS missing %q", want)
		}
	}
	if !strings.Contains(adminCSS, ".buttonLink") {
		t.Fatal("adminCSS missing .buttonLink")
	}
}

func TestAdminUIIncludesDeviceDeleteAndSessionRestore(t *testing.T) {
	for _, want := range []string{
		`data-action="delete"`,
		`Delete</button>`,
		`confirm("Delete device "`,
		`refreshAll().then(() => showApp(true)).catch(() => showApp(false));`,
	} {
		if !strings.Contains(adminJS, want) {
			t.Fatalf("adminJS missing %q", want)
		}
	}
}

func TestAdminUIIncludesSessionControls(t *testing.T) {
	for _, want := range []string{
		`id="sessions"`,
		`id="revokeOthers"`,
		`/api/admin/sessions`,
		`/api/admin/sessions/revoke-others`,
		`data-session-action="revoke"`,
	} {
		if !strings.Contains(adminHTML+adminJS, want) {
			t.Fatalf("admin UI missing %q", want)
		}
	}
	if !strings.Contains(adminCSS, ".sessionItem") {
		t.Fatal("adminCSS missing .sessionItem")
	}
}
