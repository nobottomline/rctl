package relay

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"html"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

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
	body := `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Join a device session · rctl</title><style>
 :root{color-scheme:dark}body{margin:0;min-height:100svh;display:grid;place-items:center;background:#0d1117;color:#e6edf3;font:16px system-ui}main{max-width:30rem;padding:2rem}h1{font-size:1.7rem}p{line-height:1.6;color:#aeb8c6}button,a{font:inherit}button{border:0;border-radius:10px;background:#a3e635;color:#17210c;padding:.8rem 1.3rem;font-weight:650}button:disabled{opacity:.5}#error{color:#fda4af}#resume{color:#a3e635}
 </style></head><body><main><p>rctl · Temporary access</p><h1>Join a device session</h1><p>Only the actions selected by the owner will be available. Access ends when its time expires or the owner disconnects you.</p><button id="join" type="button">Join session</button><p id="error" role="alert"></p><a id="resume" href="/guest/control" hidden>Return to your current session</a></main><script nonce="` + nonce + `">
 const secret=location.hash.slice(1);const invitation=location.pathname.split('/').pop();history.replaceState(null,'',location.pathname);
 const button=document.getElementById('join'),error=document.getElementById('error');let prepared=false;
 async function post(path,body){const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});const j=await r.json();if(!r.ok)throw new Error(j.error||'Connection failed');return j}
 if(!secret){button.disabled=true;error.textContent='Open the complete invitation from the owner, or return to an existing session.';document.getElementById('resume').hidden=false}
 button.onclick=async()=>{button.disabled=true;error.textContent='';try{if(!prepared){await post('/api/guest/prepare',{});prepared=true}await post('/api/guest/claim',{invitation_id:invitation,secret});try{await post('/api/guest/claim/ack',{})}catch{}location.replace('/guest/control')}catch(e){const labels={invitation_unavailable:'This invitation has expired, was already used, or was revoked.',device_offline:'The device is offline. You can retry while the invitation is valid.',device_guest_access_not_supported:'The device needs an update before it can accept guests.',turn_unavailable:'The relay connection is unavailable. Contact the owner.',end_current_session_first:'End your current session before joining another invitation.',claim_binding_required:'The join confirmation expired. Retry to prepare a new confirmation.'};if(e.message==='claim_binding_required')prepared=false;if(e.message==='end_current_session_first'){document.getElementById('resume').hidden=false}error.textContent=labels[e.message]||'Could not confirm the connection. Retry this page or contact the owner.';button.disabled=false}};
 </script></body></html>`
	writeText(w, 200, "text/html; charset=utf-8", body)
}
func guestErrorPage(w http.ResponseWriter, status int, message string) {
	nonce := guestNonce()
	guestPageHeaders(w, nonce)
	page := `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Temporary access · rctl</title><style>:root{color-scheme:dark}body{max-width:32rem;margin:15vh auto;padding:2rem;font:16px system-ui;background:#0d1117;color:#e6edf3}p{line-height:1.6;color:#aeb8c6}a{color:#b4dc78}</style></head><body><main><h1>Device session unavailable</h1><p>` + html.EscapeString(message) + `</p><a href="/guest/control">Try again</a></main></body></html>`
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
