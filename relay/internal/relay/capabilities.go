package relay

import "net/http"

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

func (s *server) features() []string {
	features := append([]string(nil), relayFeatures...)
	if len(s.publicPackage) != 0 {
		features = append(features, "package.personalization")
	}
	return features
}

func (s *server) handleCapabilities(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"product":   "rctl",
		"component": "relay",
		"relay":     map[string]any{"version": Version},
		"protocol":  map[string]int{"major": protocolMajor, "minor": protocolMinor},
		"features":  s.features(),
	})
}
