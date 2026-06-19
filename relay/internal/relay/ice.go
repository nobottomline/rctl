package relay

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"strconv"
	"time"
)

// iceServer is one entry of the WebRTC RTCIceServer list handed to both the
// browser and the device so ICE can traverse NAT/CGNAT (STUN to discover the
// public mapping, TURN to relay when hole-punching fails).
type iceServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

// iceServersJSON builds the RTCIceServer list for a session: the STUN servers
// (no auth) plus the TURN servers with a short-lived credential. We use coturn's
// shared-secret scheme (use-auth-secret / the "TURN REST API"): the credential
// is never stored — username = "<expiry-unix>:<id>" and credential =
// base64(HMAC-SHA1(secret, username)), which coturn recomputes and time-checks.
// Returns nil when no TURN/STUN is configured (ICE then falls back to host
// candidates only — same-LAN reach, as before TURN was added).
func (s *server) iceServersJSON(id string) json.RawMessage {
	var servers []iceServer
	if len(s.cfg.StunURLs) > 0 {
		servers = append(servers, iceServer{URLs: s.cfg.StunURLs})
	}
	if s.cfg.TurnSecret != "" && len(s.cfg.TurnURLs) > 0 {
		ttl := s.cfg.TurnTTL
		if ttl <= 0 {
			ttl = time.Hour
		}
		username := strconv.FormatInt(time.Now().Add(ttl).Unix(), 10) + ":" + id
		mac := hmac.New(sha1.New, []byte(s.cfg.TurnSecret))
		mac.Write([]byte(username))
		servers = append(servers, iceServer{
			URLs:       s.cfg.TurnURLs,
			Username:   username,
			Credential: base64.StdEncoding.EncodeToString(mac.Sum(nil)),
		})
	}
	if len(servers) == 0 {
		return nil
	}
	b, err := json.Marshal(servers)
	if err != nil {
		return nil
	}
	return b
}
