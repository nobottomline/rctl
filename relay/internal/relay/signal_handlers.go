package relay

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"sort"

	"nhooyr.io/websocket"
)

// signalTunnelEvent is the opaque WebRTC signaling envelope multiplexed over the
// device's main control websocket. The relay never parses SDP or ICE — Payload
// is forwarded verbatim between an admin /signal websocket and the device,
// keyed by the per-connection session id.
type signalTunnelEvent struct {
	Type    string          `json:"type"`
	ID      string          `json:"id"`
	Kind    string          `json:"kind"`
	Payload json.RawMessage `json:"payload,omitempty"`
}

// signalClientMessage is the browser-facing message on the /signal websocket.
type signalClientMessage struct {
	Kind    string          `json:"kind"`
	Payload json.RawMessage `json:"payload,omitempty"`
}

type signalOpenPayload struct {
	AuthorizationRevision int64           `json:"authorization_revision,omitempty"`
	Role                  string          `json:"role"`
	ICE                   json.RawMessage `json:"ice"`
	Scopes                []string        `json:"scopes,omitempty"`
}

const (
	signalSDPMaxBytes       = 262_144
	signalCandidateMaxBytes = 4_096
	signalMIDMaxBytes       = 256
)

func validControllerSignalMessage(message signalClientMessage) bool {
	switch message.Kind {
	case "answer":
		var payload struct {
			SDP *string `json:"sdp"`
		}
		return json.Unmarshal(message.Payload, &payload) == nil &&
			payload.SDP != nil && len(*payload.SDP) > 0 && len(*payload.SDP) <= signalSDPMaxBytes
	case "candidate":
		var payload struct {
			Candidate *string `json:"candidate"`
			MID       *string `json:"mid"`
		}
		return json.Unmarshal(message.Payload, &payload) == nil &&
			payload.Candidate != nil && payload.MID != nil &&
			len(*payload.Candidate) > 0 && len(*payload.Candidate) <= signalCandidateMaxBytes &&
			len(*payload.MID) <= signalMIDMaxBytes
	default:
		return false
	}
}

func validDeviceSignalMessage(message signalTunnelEvent) bool {
	if message.Kind == "authorization_challenge" {
		_, ok := parseAuthorizationChallenge(message.Payload)
		return ok
	}
	if message.Kind == "close" {
		return len(message.Payload) == 0 || string(message.Payload) == "null"
	}
	clientMessage := signalClientMessage{Kind: message.Kind, Payload: message.Payload}
	if message.Kind == "offer" {
		clientMessage.Kind = "answer"
	}
	return (message.Kind == "offer" || message.Kind == "candidate") &&
		validControllerSignalMessage(clientMessage)
}

// handleSignalWS bridges a browser WebRTC signaling websocket to an approved,
// online device. The signaling session is the websocket connection itself; the
// relay only routes opaque sdp/ice payloads in both directions.
func (s *server) handleSignalWS(w http.ResponseWriter, r *http.Request) {
	if !s.cfg.EnableWebRTC {
		writeErr(w, http.StatusNotFound, "webrtc_disabled")
		return
	}
	role := r.URL.Query().Get("media")
	if role == "" {
		role = "screen"
	}
	if role != "screen" && role != "camera" {
		writeErr(w, http.StatusBadRequest, "invalid_media_role")
		return
	}
	scopes, controllerID, ok := controllerSignalScopes(r, role)
	if !ok {
		writeErr(w, http.StatusForbidden, "insufficient_scope")
		return
	}
	deviceID := r.PathValue("id")
	dc := s.getDevice(deviceID)
	if dc == nil {
		writeErr(w, http.StatusNotFound, "device_offline")
		return
	}
	if !s.deviceApproved(r.Context(), deviceID) {
		writeErr(w, http.StatusForbidden, "device_not_approved")
		return
	}
	if controllerID != "" && !hasFeature(dc.features, "controller.scoped_sessions") {
		writeErr(w, http.StatusConflict, "device_scoped_sessions_not_supported")
		return
	}
	if controllerID != "" && !hasFeature(dc.features, "controller.authorization_lease_v1") {
		writeErr(w, http.StatusConflict, "device_authorization_lease_not_supported")
		return
	}
	principal, _ := controllerFromContext(r.Context())

	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: s.cfg.AllowInsecure})
	if err != nil {
		return
	}
	ws.SetReadLimit(s.cfg.ReadLimitBytes)
	defer ws.Close(websocket.StatusNormalClosure, "")

	sessionID := "sig_" + randomHex(12)
	sessionContext := r.Context()
	if controllerID != "" {
		var cancelControllerSignal context.CancelFunc
		sessionContext, cancelControllerSignal = context.WithCancel(r.Context())
		s.controllerGrantsMu.Lock()
		s.registerControllerSignal(controllerID, sessionID, cancelControllerSignal)
		current := s.controllerGrantCurrent(sessionContext, controllerID, principal.AuthorizationRevision)
		s.controllerGrantsMu.Unlock()
		defer func() {
			s.unregisterControllerSignal(controllerID, sessionID)
			if sessionContext.Err() != nil {
				_ = ws.Close(websocket.StatusPolicyViolation, "controller authorization changed")
			}
			cancelControllerSignal()
		}()
		// A revocation can commit between request authentication and registration.
		// Once registered, later revocations cancel this context as usual.
		if !current {
			_ = ws.Close(websocket.StatusPolicyViolation, "controller access revoked")
			return
		}
	}
	eventCh := make(chan signalTunnelEvent, 32)
	dc.registerSignal(sessionID, eventCh)
	defer func() {
		dc.unregisterSignal(sessionID)
		cancelCtx, cancel := context.WithTimeout(context.Background(), s.cfg.WriteTimeout)
		err := dc.writeJSON(cancelCtx, signalTunnelEvent{Type: "webrtc_signal", ID: sessionID, Kind: "close"})
		cancel()
		if err != nil {
			// This exact transport can no longer deliver revocations. Disconnect
			// it so the daemon drops all sessions owned by it, not a replacement.
			_ = dc.ws.CloseNow()
		}
	}()

	// Mint the ICE servers once per session (STUN + short-lived TURN creds) and
	// hand the same list to both ends: the device gets it in the "open" payload,
	// the browser in "ready". Nil when TURN/STUN isn't configured (host-only ICE).
	ice := s.iceServersJSON(sessionID)

	openCtx, cancel := context.WithTimeout(sessionContext, s.cfg.WriteTimeout)
	openPayload, _ := json.Marshal(signalOpenPayload{Role: role, ICE: ice, Scopes: scopes, AuthorizationRevision: principal.AuthorizationRevision})
	err = dc.writeJSON(openCtx, signalTunnelEvent{Type: "webrtc_signal", ID: sessionID, Kind: "open", Payload: openPayload})
	cancel()
	if err != nil {
		writeErr(w, http.StatusBadGateway, "device_write_failed")
		return
	}
	_ = wsjsonWrite(sessionContext, ws, signalClientMessage{Kind: "ready", Payload: ice})
	auditFields := []any{"device_id", deviceID, "session_id", sessionID, "media", role}
	if controllerID != "" {
		auditFields = append(auditFields, "controller_id", controllerID, "scopes", scopes)
	}
	s.audit(r, "webrtc_signal_open", auditFields...)

	readDone := make(chan struct{})
	readContext, stopRead := context.WithCancel(r.Context())
	defer stopRead()
	go func() {
		defer close(readDone)
		for {
			messageType, payload, err := ws.Read(readContext)
			if err != nil {
				return
			}
			var msg signalClientMessage
			if messageType != websocket.MessageText || json.Unmarshal(payload, &msg) != nil ||
				!validControllerSignalMessage(msg) {
				_ = ws.Close(websocket.StatusUnsupportedData, "invalid signaling message")
				return
			}
			out := signalTunnelEvent{Type: "webrtc_signal", ID: sessionID, Kind: msg.Kind, Payload: msg.Payload}
			writeCtx, cancel := context.WithTimeout(sessionContext, s.cfg.WriteTimeout)
			err = dc.writeJSON(writeCtx, out)
			cancel()
			if err != nil {
				return
			}
		}
	}()

	for {
		select {
		case event, ok := <-eventCh:
			if !ok {
				return
			}
			if event.Kind == "close" {
				return
			}
			if event.Kind == "authorization_challenge" {
				challenge, valid := parseAuthorizationChallenge(event.Payload)
				if !valid || controllerID == "" || challenge.Revision != principal.AuthorizationRevision ||
					!s.controllerGrantCurrent(sessionContext, controllerID, principal.AuthorizationRevision) {
					return
				}
				// Never forward challenges to a controller. Only this authenticated
				// device transport can renew its session's current grant.
				ctx, cancel := context.WithTimeout(sessionContext, s.cfg.WriteTimeout)
				err := dc.writeJSON(ctx, signalTunnelEvent{Type: "webrtc_signal", ID: sessionID, Kind: "authorization_renew", Payload: event.Payload})
				cancel()
				if err != nil {
					return
				}
				continue
			}
			writeCtx, cancel := context.WithTimeout(sessionContext, s.cfg.WriteTimeout)
			err := wsjsonWrite(writeCtx, ws, signalClientMessage{Kind: event.Kind, Payload: event.Payload})
			cancel()
			if err != nil {
				return
			}
		case <-readDone:
			return
		case <-sessionContext.Done():
			_ = ws.Close(websocket.StatusPolicyViolation, "controller authorization changed")
			return
		}
	}
}

type authorizationChallenge struct {
	Revision int64  `json:"authorization_revision"`
	Nonce    string `json:"nonce"`
}

func parseAuthorizationChallenge(payload json.RawMessage) (authorizationChallenge, bool) {
	var value authorizationChallenge
	if len(payload) > 256 || json.Unmarshal(payload, &value) != nil || value.Revision < 1 || value.Revision > 9007199254740991 {
		return value, false
	}
	decoded, err := hex.DecodeString(value.Nonce)
	return value, err == nil && len(decoded) == 32
}

func (s *server) registerControllerSignal(controllerID, sessionID string, cancel context.CancelFunc) {
	s.controllerSignalsMu.Lock()
	defer s.controllerSignalsMu.Unlock()
	if s.controllerSignals == nil {
		s.controllerSignals = make(map[string]map[string]context.CancelFunc)
	}
	if s.controllerSignals[controllerID] == nil {
		s.controllerSignals[controllerID] = make(map[string]context.CancelFunc)
	}
	s.controllerSignals[controllerID][sessionID] = cancel
}

func (s *server) unregisterControllerSignal(controllerID, sessionID string) {
	s.controllerSignalsMu.Lock()
	defer s.controllerSignalsMu.Unlock()
	sessions := s.controllerSignals[controllerID]
	delete(sessions, sessionID)
	if len(sessions) == 0 {
		delete(s.controllerSignals, controllerID)
	}
}

func (s *server) closeControllerSignals(controllerID string) {
	s.controllerSignalsMu.Lock()
	sessions := s.controllerSignals[controllerID]
	delete(s.controllerSignals, controllerID)
	s.controllerSignalsMu.Unlock()
	for _, cancel := range sessions {
		cancel()
	}
}

// An admin-authenticated browser has the legacy full-trust path and therefore
// omits scopes from the device open envelope. A native controller must have the
// scope that exposes the selected media track; all of its scopes are forwarded
// to the authenticated device so it can omit unauthorized P2P DataChannels.
func controllerSignalScopes(r *http.Request, role string) ([]string, string, bool) {
	principal, isController := controllerFromContext(r.Context())
	if !isController {
		return nil, "", true
	}
	required := "screen.view"
	if role == "camera" {
		required = "camera"
	}
	if _, allowed := principal.Scopes[required]; !allowed {
		return nil, principal.ControllerID, false
	}
	scopes := make([]string, 0, len(principal.Scopes))
	for scope := range principal.Scopes {
		scopes = append(scopes, scope)
	}
	sort.Strings(scopes)
	return scopes, principal.ControllerID, true
}

func (dc *deviceConn) registerSignal(id string, ch chan signalTunnelEvent) {
	dc.mu.Lock()
	dc.pendingSignal[id] = ch
	dc.mu.Unlock()
}

func (dc *deviceConn) unregisterSignal(id string) {
	dc.mu.Lock()
	delete(dc.pendingSignal, id)
	dc.mu.Unlock()
}

func (dc *deviceConn) sendSignalEvent(id string, ch chan signalTunnelEvent, event signalTunnelEvent) {
	select {
	case ch <- event:
	default:
		dc.closeSignal(id, ch)
	}
}

func (dc *deviceConn) closeSignal(id string, ch chan signalTunnelEvent) {
	dc.mu.Lock()
	if dc.pendingSignal[id] == ch {
		delete(dc.pendingSignal, id)
		close(ch)
	}
	dc.mu.Unlock()
}
