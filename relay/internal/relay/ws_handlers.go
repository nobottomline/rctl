package relay

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"nhooyr.io/websocket"
)

type deviceConn struct {
	id             string
	name           string
	daemonVersion  string
	browserVersion string
	protocolMajor  int
	protocolMinor  int
	features       []string
	ws             *websocket.Conn

	mu             sync.Mutex
	writeMu        sync.Mutex
	viewer         *websocket.Conn
	lastRecvAt     time.Time // last time any frame arrived from the device (liveness)
	pendingHTTP    map[string]chan httpTunnelResponse
	pendingHTTPBuf map[string]*strings.Builder // accumulates a chunked http response body (base64) by request id
	pendingStream  map[string]chan streamTunnelEvent
	pendingTerm    map[string]chan termTunnelEvent
	pendingSignal  map[string]chan signalTunnelEvent
}

func (s *server) handleDeviceWS(w http.ResponseWriter, r *http.Request) {
	token := bearerToken(r)
	if token == "" {
		writeErr(w, http.StatusUnauthorized, "missing_bearer_token")
		return
	}
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: s.cfg.AllowInsecure})
	if err != nil {
		return
	}
	ws.SetReadLimit(s.cfg.ReadLimitBytes)
	defer ws.Close(websocket.StatusInternalError, "server error")

	var hello struct {
		Type           string `json:"type"`
		DeviceID       string `json:"device_id"`
		DeviceName     string `json:"device_name"`
		DaemonVersion  string `json:"daemon_version"`
		BrowserVersion string `json:"browser_version"`
		Protocol       struct {
			Major int `json:"major"`
			Minor int `json:"minor"`
		} `json:"protocol"`
		Features []string `json:"features"`
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	if err := wsjsonRead(ctx, ws, &hello); err != nil || hello.Type != "hello" {
		ws.Close(websocket.StatusUnsupportedData, "expected hello")
		return
	}
	hello.DeviceName = normalizeDeviceName(hello.DeviceName)
	if len(hello.DaemonVersion) > 64 || len(hello.BrowserVersion) > 64 || len(hello.Features) > 128 {
		ws.Close(websocket.StatusUnsupportedData, "invalid capabilities")
		return
	}
	legacyProtocol := hello.Protocol.Major == 0
	if legacyProtocol {
		// Rolling-upgrade bridge for daemon builds that predate negotiation. They
		// spoke protocol 1; this lets operators upgrade the relay first.
		hello.Protocol.Major = protocolMajor
	}
	cleanFeatures := make([]string, 0, len(hello.Features))
	for _, feature := range hello.Features {
		feature = strings.TrimSpace(feature)
		if feature != "" && len(feature) <= 96 {
			cleanFeatures = append(cleanFeatures, feature)
		}
	}
	hello.Features = cleanFeatures
	capabilitiesJSON, _ := json.Marshal(hello.Features)
	if !protocolCompatible(hello.Protocol.Major) {
		// Never consume a one-time enrollment token for a daemon this relay cannot
		// serve. For already-approved devices the secret identifies the DB row, so
		// the admin panel can surface the incompatibility without trusting DeviceID.
		deviceID, secretErr := s.authenticateDeviceSecret(r.Context(), token)
		if secretErr == nil {
			_, _ = s.db.ExecContext(r.Context(), `
UPDATE devices
SET daemon_version=?, browser_version=?, protocol_major=?, protocol_minor=?,
    capabilities_json=?, compatibility_error='protocol_major_mismatch', updated_at=?
WHERE id=?`, hello.DaemonVersion, hello.BrowserVersion, hello.Protocol.Major,
				hello.Protocol.Minor, string(capabilitiesJSON), time.Now().Unix(), deviceID)
		}
		s.audit(r, "device_protocol_rejected", "claimed_device_id", hello.DeviceID,
			"device_protocol_major", hello.Protocol.Major, "relay_protocol_major", protocolMajor,
			"authenticated", secretErr == nil)
		ws.Close(websocket.StatusPolicyViolation, "protocol major incompatible")
		return
	}

	deviceID, status, err := s.authenticateDevice(r, token, hello.DeviceID, hello.DeviceName)
	if err != nil {
		s.audit(r, "device_auth_failed", "claimed_device_id", hello.DeviceID, "reason", err.Error())
		s.log.Warn("device auth rejected", "error", err)
		ws.Close(websocket.StatusPolicyViolation, "auth rejected")
		return
	}
	_, _ = s.db.ExecContext(r.Context(), `
UPDATE devices
SET daemon_version=?, browser_version=?, protocol_major=?, protocol_minor=?,
    capabilities_json=?, compatibility_error=?, updated_at=?
WHERE id=?`, hello.DaemonVersion, hello.BrowserVersion, hello.Protocol.Major,
		hello.Protocol.Minor, string(capabilitiesJSON), "", time.Now().Unix(), deviceID)

	dc := &deviceConn{
		id:             deviceID,
		name:           hello.DeviceName,
		daemonVersion:  hello.DaemonVersion,
		browserVersion: hello.BrowserVersion,
		protocolMajor:  hello.Protocol.Major,
		protocolMinor:  hello.Protocol.Minor,
		features:       append([]string(nil), hello.Features...),
		ws:             ws,
		lastRecvAt:     time.Now(),
		pendingHTTP:    make(map[string]chan httpTunnelResponse),
		pendingHTTPBuf: make(map[string]*strings.Builder),
		pendingStream:  make(map[string]chan streamTunnelEvent),
		pendingTerm:    make(map[string]chan termTunnelEvent),
		pendingSignal:  make(map[string]chan signalTunnelEvent),
	}
	s.registerDevice(dc)
	defer s.unregisterDevice(deviceID, dc)
	defer ws.Close(websocket.StatusNormalClosure, "")

	_ = wsjsonWrite(r.Context(), ws, map[string]any{
		"type": "hello_ack", "device_id": deviceID, "status": status,
		"relay_version":   Version,
		"protocol":        map[string]int{"major": protocolMajor, "minor": protocolMinor},
		"features":        relayFeatures,
		"legacy_protocol": legacyProtocol,
	})
	s.audit(r, "device_connected", "device_id", deviceID, "status", status)
	s.log.Info("device connected", "device_id", deviceID, "status", status)
	hbCtx, hbCancel := context.WithCancel(r.Context())
	defer hbCancel()
	go s.deviceHeartbeat(hbCtx, dc)
	s.deviceReadLoop(r.Context(), dc)
	s.audit(r, "device_disconnected", "device_id", deviceID)
}

func (s *server) handleClientWS(w http.ResponseWriter, r *http.Request) {
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

	dc.mu.Lock()
	if dc.viewer != nil {
		dc.mu.Unlock()
		ws.Close(websocket.StatusPolicyViolation, "device already has a viewer")
		return
	}
	dc.viewer = ws
	dc.mu.Unlock()

	defer func() {
		dc.mu.Lock()
		if dc.viewer == ws {
			dc.viewer = nil
		}
		dc.mu.Unlock()
		ws.Close(websocket.StatusNormalClosure, "")
	}()

	s.log.Info("client connected", "device_id", deviceID)
	for {
		msgType, payload, err := ws.Read(r.Context())
		if err != nil {
			return
		}
		writeCtx, cancel := context.WithTimeout(r.Context(), s.cfg.WriteTimeout)
		err = dc.write(writeCtx, msgType, payload)
		cancel()
		if err != nil {
			return
		}
	}
}

func (s *server) authenticateDevice(r *http.Request, token, claimedID, name string) (string, string, error) {
	ctx := r.Context()
	now := time.Now().Unix()
	tokenHash := hashToken(token)
	var status string
	var deviceID string
	err := s.db.QueryRowContext(ctx, `SELECT id, status FROM devices WHERE device_secret_hash=? AND status='approved'`, tokenHash).Scan(&deviceID, &status)
	if err == nil {
		_, _ = s.db.ExecContext(ctx, `UPDATE devices SET name=?, updated_at=?, last_seen_at=? WHERE id=?`, name, now, now, deviceID)
		s.audit(r, "device_secret_authenticated", "device_id", deviceID)
		return deviceID, status, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", "", err
	}

	// Otherwise the token must be a one-time enrollment token. Claiming an
	// enrollment may only CREATE a new pending device, never adopt an existing
	// id: a leaked enrollment token must not be able to hijack the identity of
	// an already-approved device. The check, insert, and single-use consumption
	// run in one transaction so the token cannot be claimed twice concurrently.
	claimedID, ok := normalizeDeviceID(claimedID)
	if !ok {
		return "", "", errors.New("invalid device id")
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", "", err
	}
	defer tx.Rollback()

	var enrollmentID string
	var expiresAt int64
	var usedAt, revokedAt sql.NullInt64
	err = tx.QueryRowContext(ctx, `SELECT id, expires_at, used_at, revoked_at FROM enrollments WHERE token_hash=?`, tokenHash).Scan(&enrollmentID, &expiresAt, &usedAt, &revokedAt)
	if err != nil {
		return "", "", errors.New("invalid token")
	}
	if revokedAt.Valid {
		return "", "", errors.New("enrollment revoked")
	}
	if usedAt.Valid {
		return "", "", errors.New("enrollment already used")
	}
	if expiresAt < now {
		return "", "", errors.New("enrollment expired")
	}

	var existing int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices WHERE id=?`, claimedID).Scan(&existing); err != nil {
		return "", "", err
	}
	if existing != 0 {
		return "", "", errors.New("device id already registered")
	}

	if _, err := tx.ExecContext(ctx, `
INSERT INTO devices(id, name, status, enroll_token_hash, created_at, updated_at, last_seen_at)
VALUES(?, ?, 'pending', ?, ?, ?, ?)`, claimedID, name, tokenHash, now, now, now); err != nil {
		return "", "", err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE enrollments SET used_at=? WHERE id=?`, now, enrollmentID); err != nil {
		return "", "", err
	}
	if err := tx.Commit(); err != nil {
		return "", "", err
	}

	s.audit(r, "device_enrollment_claimed", "device_id", claimedID, "enrollment_id", enrollmentID)
	return claimedID, "pending", nil
}

func (s *server) authenticateDeviceSecret(ctx context.Context, token string) (string, error) {
	tokenHash := hashToken(token)
	var deviceID string
	err := s.db.QueryRowContext(ctx, `SELECT id FROM devices WHERE device_secret_hash=? AND status='approved'`, tokenHash).Scan(&deviceID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", errors.New("invalid token")
		}
		return "", err
	}
	return deviceID, nil
}

// deviceHeartbeat pings the device connection on the configured interval. Pings
// keep the relay->device path non-idle so a NAT/firewall does not silently drop
// an idle WebSocket (the cause of devices going stale-online), and detect a dead
// peer: a ping with no pong within the write timeout closes the connection so the
// read loop exits, the device is marked offline, and the device reconnects.
func (s *server) deviceHeartbeat(ctx context.Context, dc *deviceConn) {
	if s.cfg.HeartbeatEvery <= 0 {
		return
	}
	// An idle iOS device refreshes its own activity timer from INBOUND traffic
	// (an arriving packet wakes its network stack) but throttles its OUTBOUND
	// keepalive timers — so it would otherwise declare its own healthy link dead
	// and reconnect. Send a frequent app-level ping the device can observe; cap
	// the interval well below the device's stale window so its throttled timing
	// can't false-trigger a drop.
	interval := s.cfg.HeartbeatEvery
	if interval > 15*time.Second {
		interval = 15 * time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			reqCtx, cancel := context.WithTimeout(ctx, s.cfg.WriteTimeout)
			// App-level ping keeps the NAT path warm and prompts the device's pong.
			// We deliberately do NOT use a protocol ping/pong for liveness: a device
			// that's busy (mid large-response, or streaming) can be slow to pong
			// without being dead, and closing it there drops the relay link
			// mid-transfer -- exactly what broke camera/large responses.
			writeErr := dc.writeJSON(reqCtx, map[string]any{"type": "ping"})
			cancel()
			if writeErr != nil {
				// Can't even send -> the link really is broken.
				s.log.Info("heartbeat closing device", "device_id", dc.id, "reason", "write_failed", "error", writeErr.Error())
				_ = dc.ws.Close(websocket.StatusPolicyViolation, "heartbeat write failed")
				return
			}
			// Liveness = RECEIVED activity: the device pongs every tick and streams
			// signaling/response frames, so genuine silence (nothing at all for a few
			// intervals) is the only true-dead signal. A busy device stays connected.
			dc.mu.Lock()
			silent := time.Since(dc.lastRecvAt)
			dc.mu.Unlock()
			if silent > 3*interval {
				s.log.Info("heartbeat closing device", "device_id", dc.id, "reason", "silent", "silent_ms", silent.Milliseconds())
				_ = dc.ws.Close(websocket.StatusPolicyViolation, "device silent")
				return
			}
		}
	}
}

func (s *server) deviceReadLoop(ctx context.Context, dc *deviceConn) {
	for {
		msgType, payload, err := dc.ws.Read(ctx)
		if err != nil {
			s.log.Info("device read loop ended", "device_id", dc.id, "error", err.Error())
			return
		}
		dc.mu.Lock()
		dc.lastRecvAt = time.Now() // any frame proves the device is alive
		dc.mu.Unlock()
		if msgType == websocket.MessageText && dc.handleControlMessage(payload) {
			continue
		}
		dc.mu.Lock()
		viewer := dc.viewer
		dc.mu.Unlock()
		if viewer != nil {
			writeCtx, cancel := context.WithTimeout(ctx, s.cfg.WriteTimeout)
			_ = viewer.Write(writeCtx, msgType, payload)
			cancel()
		}
	}
}

func (s *server) handleDeviceStreamWS(w http.ResponseWriter, r *http.Request) {
	token := bearerToken(r)
	if token == "" {
		writeErr(w, http.StatusUnauthorized, "missing_bearer_token")
		return
	}
	deviceID, err := s.authenticateDeviceSecret(r.Context(), token)
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "auth_rejected")
		return
	}
	dc := s.getDevice(deviceID)
	if dc == nil {
		writeErr(w, http.StatusNotFound, "device_offline")
		return
	}
	streamID := r.PathValue("streamID")
	ch := dc.streamChannel(streamID)
	if ch == nil {
		writeErr(w, http.StatusNotFound, "stream_not_found")
		return
	}
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: s.cfg.AllowInsecure})
	if err != nil {
		return
	}
	ws.SetReadLimit(s.cfg.ReadLimitBytes)
	defer ws.Close(websocket.StatusNormalClosure, "")

	for {
		msgType, payload, err := ws.Read(r.Context())
		if err != nil {
			dc.sendStreamEvent(streamID, ch, streamTunnelEvent{Type: "stream_end", ID: streamID})
			return
		}
		switch msgType {
		case websocket.MessageText:
			var event streamTunnelEvent
			if json.Unmarshal(payload, &event) != nil {
				continue
			}
			if event.ID == "" {
				event.ID = streamID
			}
			if event.ID != streamID {
				continue
			}
			dc.sendStreamEvent(streamID, ch, event)
			if event.Type == "stream_end" {
				return
			}
		case websocket.MessageBinary:
			chunk := append([]byte(nil), payload...)
			dc.sendStreamEvent(streamID, ch, streamTunnelEvent{Type: "stream_chunk", ID: streamID, BodyBytes: chunk})
		}
	}
}

func (dc *deviceConn) handleControlMessage(payload []byte) bool {
	var envelope struct {
		Type string `json:"type"`
		ID   string `json:"id"`
	}
	if json.Unmarshal(payload, &envelope) != nil {
		return false
	}
	// Heartbeat chatter from the device (its reply to our keep-alive ping); it
	// carries no id and routes nowhere, so swallow it instead of forwarding it
	// to a viewer.
	if envelope.Type == "pong" || envelope.Type == "ping" {
		return true
	}
	if envelope.ID == "" {
		return false
	}
	switch envelope.Type {
	case "http_response":
		var response httpTunnelResponse
		if json.Unmarshal(payload, &response) != nil {
			return true
		}
		dc.mu.Lock()
		ch := dc.pendingHTTP[envelope.ID]
		if ch != nil {
			delete(dc.pendingHTTP, envelope.ID)
		}
		dc.mu.Unlock()
		if ch != nil {
			ch <- response
		}
	case "http_response_chunk":
		// A large response body is split across messages -- a single multi-MB WS
		// message drops the device's connection on iOS. Accumulate the base64 parts.
		var c struct {
			Data string `json:"data"`
		}
		if json.Unmarshal(payload, &c) != nil {
			return true
		}
		dc.mu.Lock()
		if dc.pendingHTTPBuf == nil {
			dc.pendingHTTPBuf = make(map[string]*strings.Builder)
		}
		b := dc.pendingHTTPBuf[envelope.ID]
		if b == nil {
			b = &strings.Builder{}
			dc.pendingHTTPBuf[envelope.ID] = b
		}
		b.WriteString(c.Data)
		dc.mu.Unlock()
	case "http_response_end":
		var response httpTunnelResponse
		if json.Unmarshal(payload, &response) != nil {
			return true
		}
		dc.mu.Lock()
		if b := dc.pendingHTTPBuf[envelope.ID]; b != nil {
			response.Body = b.String()
			delete(dc.pendingHTTPBuf, envelope.ID)
		}
		ch := dc.pendingHTTP[envelope.ID]
		if ch != nil {
			delete(dc.pendingHTTP, envelope.ID)
		}
		dc.mu.Unlock()
		if ch != nil {
			ch <- response
		}
	case "stream_start", "stream_chunk", "stream_end":
		var event streamTunnelEvent
		if json.Unmarshal(payload, &event) != nil {
			return true
		}
		dc.mu.Lock()
		ch := dc.pendingStream[envelope.ID]
		if envelope.Type == "stream_end" && ch != nil {
			delete(dc.pendingStream, envelope.ID)
		}
		dc.mu.Unlock()
		if ch != nil {
			dc.sendStreamEvent(envelope.ID, ch, event)
		}
	case "term_data", "term_close", "term_error":
		var event termTunnelEvent
		if json.Unmarshal(payload, &event) != nil {
			return true
		}
		dc.mu.Lock()
		ch := dc.pendingTerm[envelope.ID]
		if (envelope.Type == "term_close" || envelope.Type == "term_error") && ch != nil {
			delete(dc.pendingTerm, envelope.ID)
		}
		dc.mu.Unlock()
		if ch != nil {
			select {
			case ch <- event:
			default:
				dc.closeTerm(envelope.ID, ch)
			}
		}
	case "webrtc_signal":
		var event signalTunnelEvent
		if json.Unmarshal(payload, &event) != nil || !validDeviceSignalMessage(event) {
			return true
		}
		dc.mu.Lock()
		ch := dc.pendingSignal[envelope.ID]
		if event.Kind == "close" && ch != nil {
			delete(dc.pendingSignal, envelope.ID)
		}
		dc.mu.Unlock()
		if ch != nil {
			dc.sendSignalEvent(envelope.ID, ch, event)
		}
	default:
		return false
	}
	return true
}

func (dc *deviceConn) registerHTTP(id string, ch chan httpTunnelResponse) {
	dc.mu.Lock()
	dc.pendingHTTP[id] = ch
	dc.mu.Unlock()
}

func (dc *deviceConn) unregisterHTTP(id string) {
	dc.mu.Lock()
	delete(dc.pendingHTTP, id)
	delete(dc.pendingHTTPBuf, id)
	dc.mu.Unlock()
}

func (dc *deviceConn) registerStream(id string, ch chan streamTunnelEvent) {
	dc.mu.Lock()
	dc.pendingStream[id] = ch
	dc.mu.Unlock()
}

func (dc *deviceConn) registerTerm(id string, ch chan termTunnelEvent) {
	dc.mu.Lock()
	dc.pendingTerm[id] = ch
	dc.mu.Unlock()
}

func (dc *deviceConn) unregisterTerm(id string) {
	dc.mu.Lock()
	delete(dc.pendingTerm, id)
	dc.mu.Unlock()
}

func (dc *deviceConn) closeTerm(id string, ch chan termTunnelEvent) {
	dc.mu.Lock()
	if dc.pendingTerm[id] == ch {
		delete(dc.pendingTerm, id)
		close(ch)
	}
	dc.mu.Unlock()
}

func (dc *deviceConn) unregisterStream(id string) {
	dc.mu.Lock()
	delete(dc.pendingStream, id)
	dc.mu.Unlock()
}

func (dc *deviceConn) streamChannel(id string) chan streamTunnelEvent {
	dc.mu.Lock()
	defer dc.mu.Unlock()
	return dc.pendingStream[id]
}

func (dc *deviceConn) sendStreamEvent(id string, ch chan streamTunnelEvent, event streamTunnelEvent) {
	select {
	case ch <- event:
	default:
		dc.closeStream(id, ch)
	}
}

func (dc *deviceConn) closeStream(id string, ch chan streamTunnelEvent) {
	dc.mu.Lock()
	if dc.pendingStream[id] == ch {
		delete(dc.pendingStream, id)
		close(ch)
	}
	dc.mu.Unlock()
}

func (dc *deviceConn) write(ctx context.Context, msgType websocket.MessageType, payload []byte) error {
	dc.writeMu.Lock()
	defer dc.writeMu.Unlock()
	return dc.ws.Write(ctx, msgType, payload)
}

func (dc *deviceConn) writeJSON(ctx context.Context, v any) error {
	payload, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return dc.write(ctx, websocket.MessageText, payload)
}

func (s *server) registerDevice(dc *deviceConn) {
	s.mu.Lock()
	if old := s.devices[dc.id]; old != nil {
		_ = old.ws.Close(websocket.StatusPolicyViolation, "replaced by new connection")
	}
	s.devices[dc.id] = dc
	s.mu.Unlock()
}

func (s *server) unregisterDevice(id string, dc *deviceConn) {
	s.mu.Lock()
	if s.devices[id] == dc {
		delete(s.devices, id)
	}
	s.mu.Unlock()
}

func (s *server) getDevice(id string) *deviceConn {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.devices[id]
}

func (s *server) isDeviceOnline(id string) bool {
	return s.getDevice(id) != nil
}

func (s *server) closeDevice(id string, code websocket.StatusCode, reason string) {
	if dc := s.getDevice(id); dc != nil {
		_ = dc.ws.Close(code, reason)
	}
}

func (s *server) sendDeviceControl(id string, msg map[string]any) {
	if dc := s.getDevice(id); dc != nil {
		_ = dc.writeJSON(context.Background(), msg)
	}
}

func (s *server) deviceApproved(ctx context.Context, id string) bool {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices WHERE id=? AND status='approved'`, id).Scan(&n)
	return err == nil && n == 1
}

func (s *server) deviceWebSocketURL() string {
	base := strings.TrimRight(s.cfg.PublicURL, "/")
	switch {
	case strings.HasPrefix(base, "https://"):
		return "wss://" + strings.TrimPrefix(base, "https://") + "/device"
	case strings.HasPrefix(base, "http://"):
		return "ws://" + strings.TrimPrefix(base, "http://") + "/device"
	default:
		return base + "/device"
	}
}

func (s *server) deviceStreamWebSocketURL(streamID string) string {
	base := strings.TrimRight(s.cfg.PublicURL, "/")
	path := "/device-streams/" + streamID
	switch {
	case strings.HasPrefix(base, "https://"):
		return "wss://" + strings.TrimPrefix(base, "https://") + path
	case strings.HasPrefix(base, "http://"):
		return "ws://" + strings.TrimPrefix(base, "http://") + path
	default:
		return base + path
	}
}
