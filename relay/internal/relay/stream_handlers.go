package relay

import (
	"context"
	"encoding/base64"
	"net/http"
	"strings"
	"time"
)

type streamOpenRequest struct {
	Type      string `json:"type"`
	ID        string `json:"id"`
	Path      string `json:"path"`
	StreamURL string `json:"stream_url,omitempty"`
}

type streamTunnelEvent struct {
	Type        string `json:"type"`
	ID          string `json:"id"`
	Status      int    `json:"status,omitempty"`
	ContentType string `json:"content_type,omitempty"`
	Body        string `json:"body,omitempty"`
	BodyBytes   []byte `json:"-"`
	Error       string `json:"error,omitempty"`
}

func (s *server) handleTunnelStream(w http.ResponseWriter, r *http.Request) {
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

	path := "/" + strings.TrimPrefix(r.PathValue("path"), "/")
	if r.URL.RawQuery != "" {
		path += "?" + r.URL.RawQuery
	}

	streamID := "stream_" + randomHex(12)
	eventCh := make(chan streamTunnelEvent, 32)
	dc.registerStream(streamID, eventCh)
	defer func() {
		dc.unregisterStream(streamID)
		cancelCtx, cancel := context.WithTimeout(context.Background(), s.cfg.WriteTimeout)
		_ = dc.writeJSON(cancelCtx, map[string]string{"type": "stream_cancel", "id": streamID})
		cancel()
	}()

	ctx, cancel := context.WithTimeout(r.Context(), s.cfg.WriteTimeout)
	err := dc.writeJSON(ctx, streamOpenRequest{Type: "stream_open", ID: streamID, Path: path, StreamURL: s.deviceStreamWebSocketURL(streamID)})
	cancel()
	if err != nil {
		writeErr(w, http.StatusBadGateway, "device_write_failed")
		return
	}

	var started bool
	var flusher http.Flusher
	if f, ok := w.(http.Flusher); ok {
		flusher = f
	}

	startTimer := time.NewTimer(s.cfg.StreamStartTimeout)
	defer startTimer.Stop()
	startTimerCh := startTimer.C

	for {
		select {
		case event, ok := <-eventCh:
			if !ok {
				return
			}
			switch event.Type {
			case "stream_start":
				if event.Error != "" {
					writeErr(w, http.StatusBadGateway, event.Error)
					return
				}
				status := event.Status
				if status < 100 || status > 599 {
					status = http.StatusOK
				}
				if event.ContentType != "" {
					w.Header().Set("Content-Type", event.ContentType)
				}
				w.Header().Set("Cache-Control", "no-store")
				w.WriteHeader(status)
				if flusher != nil {
					flusher.Flush()
				}
				started = true
				startTimerCh = nil
			case "stream_chunk":
				if !started {
					continue
				}
				payload := event.BodyBytes
				if payload == nil {
					var err error
					payload, err = base64.StdEncoding.DecodeString(event.Body)
					if err != nil {
						return
					}
				}
				if _, err := w.Write(payload); err != nil {
					return
				}
				if flusher != nil {
					flusher.Flush()
				}
			case "stream_end":
				return
			}
		case <-startTimerCh:
			writeErr(w, http.StatusGatewayTimeout, "stream_start_timeout")
			return
		case <-r.Context().Done():
			return
		}
	}
}
