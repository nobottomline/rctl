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
	} {
		if !strings.Contains(adminJS, want) {
			t.Fatalf("adminJS missing %q", want)
		}
	}
	if !strings.Contains(adminCSS, ".buttonLink") {
		t.Fatal("adminCSS missing .buttonLink")
	}
}
