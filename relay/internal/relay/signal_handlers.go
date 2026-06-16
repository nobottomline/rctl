package relay

import (
	"context"
	"encoding/json"
	"net/http"

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

// handleSignalWS bridges a browser WebRTC signaling websocket to an approved,
// online device. The signaling session is the websocket connection itself; the
// relay only routes opaque sdp/ice payloads in both directions.
func (s *server) handleSignalWS(w http.ResponseWriter, r *http.Request) {
	if !s.cfg.EnableWebRTC {
		writeErr(w, http.StatusNotFound, "webrtc_disabled")
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

	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: s.cfg.AllowInsecure})
	if err != nil {
		return
	}
	ws.SetReadLimit(s.cfg.ReadLimitBytes)
	defer ws.Close(websocket.StatusNormalClosure, "")

	sessionID := "sig_" + randomHex(12)
	eventCh := make(chan signalTunnelEvent, 32)
	dc.registerSignal(sessionID, eventCh)
	defer func() {
		dc.unregisterSignal(sessionID)
		cancelCtx, cancel := context.WithTimeout(context.Background(), s.cfg.WriteTimeout)
		_ = dc.writeJSON(cancelCtx, signalTunnelEvent{Type: "webrtc_signal", ID: sessionID, Kind: "close"})
		cancel()
	}()

	openCtx, cancel := context.WithTimeout(r.Context(), s.cfg.WriteTimeout)
	err = dc.writeJSON(openCtx, signalTunnelEvent{Type: "webrtc_signal", ID: sessionID, Kind: "open"})
	cancel()
	if err != nil {
		writeErr(w, http.StatusBadGateway, "device_write_failed")
		return
	}
	_ = wsjsonWrite(r.Context(), ws, signalClientMessage{Kind: "ready"})
	s.audit(r, "webrtc_signal_open", "device_id", deviceID, "session_id", sessionID)

	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		for {
			_, payload, err := ws.Read(r.Context())
			if err != nil {
				return
			}
			var msg signalClientMessage
			if json.Unmarshal(payload, &msg) != nil || msg.Kind == "" {
				continue
			}
			out := signalTunnelEvent{Type: "webrtc_signal", ID: sessionID, Kind: msg.Kind, Payload: msg.Payload}
			writeCtx, cancel := context.WithTimeout(r.Context(), s.cfg.WriteTimeout)
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
			writeCtx, cancel := context.WithTimeout(r.Context(), s.cfg.WriteTimeout)
			err := wsjsonWrite(writeCtx, ws, signalClientMessage{Kind: event.Kind, Payload: event.Payload})
			cancel()
			if err != nil {
				return
			}
		case <-readDone:
			return
		case <-r.Context().Done():
			return
		}
	}
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
