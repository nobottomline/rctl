package relay

import "net/http"

const (
	protocolMajor = 1
	protocolMinor = 0
)

var relayFeatures = []string{
	"device.http_tunnel",
	"device.stream_tunnel",
	"device.terminal_tunnel",
	"webrtc.signaling",
	"admin.audit",
	"capability.negotiation",
	"update.orchestration",
}

func protocolCompatible(major int) bool {
	return major == protocolMajor
}

func (s *server) handleCapabilities(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"product":   "rctl",
		"component": "relay",
		"relay":     map[string]any{"version": Version},
		"protocol":  map[string]int{"major": protocolMajor, "minor": protocolMinor},
		"features":  relayFeatures,
	})
}
