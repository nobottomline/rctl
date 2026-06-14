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
	inject := `<script>
window.RCTL_PROXY_BASE="` + html.EscapeString(proxyBase) + `";
window.RCTL_STREAM_BASE="` + html.EscapeString(streamBase) + `";
window.RCTL_RELAY_DEVICE_ID="` + html.EscapeString(deviceID) + `";
</script>
`
	page := strings.Replace(string(raw), "<script>", inject+"<script>", 1)
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss:; img-src 'self' data: blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
	writeText(w, http.StatusOK, "text/html; charset=utf-8", page)
}

func (s *server) handleWebVendor(w http.ResponseWriter, r *http.Request) {
	name := filepath.Clean(r.PathValue("path"))
	if name == "." || strings.HasPrefix(name, "..") || filepath.IsAbs(name) {
		writeErr(w, http.StatusBadRequest, "bad_asset_path")
		return
	}
	http.ServeFile(w, r, filepath.Join(s.cfg.WebDir, "vendor", name))
}
