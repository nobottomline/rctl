package relay

import (
	"fmt"
	"html"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

func (s *server) handleControlPage(w http.ResponseWriter, r *http.Request) {
	deviceID := r.PathValue("id")
	if !s.deviceApproved(r.Context(), deviceID) {
		writeErr(w, http.StatusForbidden, "device_not_approved")
		return
	}
	if s.getDevice(deviceID) == nil {
		writeErr(w, http.StatusNotFound, "device_offline")
		return
	}
	indexPath := filepath.Join(s.cfg.WebDir, "index.html")
	raw, err := os.ReadFile(indexPath)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "web_client_missing")
		return
	}
	proxyBase := "/proxy/devices/" + deviceID
	streamBase := "/stream/devices/" + deviceID
	termBase := "/term/devices/" + deviceID
	// Tell the page WebRTC is available so it pulls video from an RTP track and
	// sends input over the control DataChannel instead of the /stream tunnel.
	webrtc := "0"
	if s.cfg.EnableWebRTC {
		webrtc = "1"
	}
	inject := `<script>
window.RCTL_PROXY_BASE="` + html.EscapeString(proxyBase) + `";
window.RCTL_STREAM_BASE="` + html.EscapeString(streamBase) + `";
window.RCTL_TERM_WS_BASE="` + html.EscapeString(termBase) + `";
window.RCTL_RELAY_DEVICE_ID="` + html.EscapeString(deviceID) + `";
window.RCTL_WEBRTC=` + webrtc + `;
window.RCTL_RELAY_VERSION="` + html.EscapeString(Version) + `";
window.RCTL_RELAY_PROTOCOL_MAJOR=` + fmt.Sprint(protocolMajor) + `;
window.RCTL_RELAY_PROTOCOL_MINOR=` + fmt.Sprint(protocolMinor) + `;
</script>
`
	page := strings.Replace(string(raw), "<head>", "<head>"+inject, 1)
	// connect-src also allows STUN/TURN schemes so RTCPeerConnection can reach the
	// ICE servers (some browsers enforce CSP on ICE URLs).
	// img-src allows https so the System Inspector can show repo package icons
	// (images only -- no frame-src, so untrusted repo HTML is never embedded here;
	// depictions open in a separate browser tab instead).
	// script-src 'wasm-unsafe-eval' lets the page compile the bundled Opus decoder
	// WASM (the iOS Safari < 26 audio fallback); it permits WASM compilation only,
	// NOT arbitrary eval, so it's far narrower than 'unsafe-eval'.
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss: stun: turn: turns:; img-src 'self' data: blob: https:; media-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
	writeText(w, http.StatusOK, "text/html; charset=utf-8", page)
}
