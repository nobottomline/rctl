package relay

import (
	"crypto/rand"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"html"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

//go:embed guest_landing.css
var guestLandingCSS string

//go:embed guest_landing.js
var guestLandingJS string

func guestPageHeaders(w http.ResponseWriter, nonce string) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'nonce-"+nonce+"' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; connect-src 'self' wss: stun: turn: turns:; img-src 'self' data: blob:; media-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; object-src 'none'")
}
func guestNonce() string {
	var b [24]byte
	if _, e := rand.Read(b[:]); e != nil {
		panic(e)
	}
	return base64.RawStdEncoding.EncodeToString(b[:])
}
func (s *server) handleGuestLanding(w http.ResponseWriter, r *http.Request) {
	// A public landing page is deliberately independent of device state and grant
	// existence. Link preview GETs cannot consume an invitation or enumerate devices.
	nonce := guestNonce()
	guestPageHeaders(w, nonce)
	body := `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Device access · rctl</title><style>` + guestLandingCSS + `</style></head><body><main><div class="brand"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><path d="M12 3 4 6v6c0 5 8 9 8 9s8-4 8-9V6l-8-3Z"/><path d="m8 12 3 3 5-6"/></svg>rctl</div><p class="eyebrow" id="status" role="status">Temporary device access</p><h1 id="heading">Connecting to your device</h1><p id="error" role="alert"></p><button id="join" type="button" hidden>Retry connection</button><a id="resume" href="/guest/control" hidden>Return to your current session</a><p class="note">Only the tools shared by the owner are available. Access ends when its time expires or the owner disconnects you.</p><noscript><p>Enable JavaScript to connect to this device.</p></noscript></main><script nonce="` + nonce + `">` + guestLandingJS + `</script></body></html>`
	writeText(w, 200, "text/html; charset=utf-8", body)
}
func guestErrorPage(w http.ResponseWriter, status int, message string) {
	nonce := guestNonce()
	guestPageHeaders(w, nonce)
	page := `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Temporary access · rctl</title><style>` + guestLandingCSS + `</style></head><body><main><div class="brand">rctl</div><p class="eyebrow">Temporary device access</p><h1>Device session unavailable</h1><p>` + html.EscapeString(message) + `</p><a href="/guest/control">Try again</a></main></body></html>`
	writeText(w, status, "text/html; charset=utf-8", page)
}

func (s *server) handleGuestControl(w http.ResponseWriter, r *http.Request) {
	p, _ := guestFromContext(r.Context())
	if e := s.guestDeviceReady(p.DeviceID, p.AllowDirect); e != "" {
		guestErrorPage(w, 409, "The device or relay connection is unavailable. Retry while your access is valid, or contact the owner.")
		return
	}
	raw, e := os.ReadFile(filepath.Join(s.cfg.WebDir, "index.html"))
	if e != nil {
		guestErrorPage(w, 503, "The device control client is unavailable. Contact the owner.")
		return
	}
	if !strings.Contains(string(raw), `name="rctl-guest-client" content="1"`) {
		guestErrorPage(w, 409, "The relay needs an updated control client before it can accept guests.")
		return
	}
	bootstrap, _ := json.Marshal(p)
	nonce := guestNonce()
	guestPageHeaders(w, nonce)
	script := `<script nonce="` + nonce + `">window.RCTL_GUEST_BOOTSTRAP=` + string(bootstrap) + `;window.RCTL_WEBRTC=1;</script>`
	page := strings.Replace(string(raw), "<script ", `<script nonce="`+nonce+`" `, 1)
	page = strings.Replace(page, "<head>", "<head>"+script, 1)
	writeText(w, 200, "text/html; charset=utf-8", page)
}
