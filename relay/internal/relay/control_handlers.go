package relay

import (
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
</script>
`
	page := strings.Replace(string(raw), "<head>", "<head>"+inject, 1)
	// connect-src also allows STUN/TURN schemes so RTCPeerConnection can reach the
	// ICE servers (some browsers enforce CSP on ICE URLs).
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss: stun: turn: turns:; img-src 'self' data: blob:; media-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
	writeText(w, http.StatusOK, "text/html; charset=utf-8", page)
}
