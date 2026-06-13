package relay

import (
	"context"
	"encoding/base64"
	"io"
	"net/http"
	"strings"
	"time"
)

type httpTunnelRequest struct {
	Type    string            `json:"type"`
	ID      string            `json:"id"`
	Method  string            `json:"method"`
	Path    string            `json:"path"`
	Headers map[string]string `json:"headers,omitempty"`
	Body    string            `json:"body,omitempty"`
}

type httpTunnelResponse struct {
	Type        string `json:"type"`
	ID          string `json:"id"`
	Status      int    `json:"status"`
	ContentType string `json:"content_type,omitempty"`
	Body        string `json:"body,omitempty"`
	Error       string `json:"error,omitempty"`
}

func (s *server) handleTunnelHTTP(w http.ResponseWriter, r *http.Request) {
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

	body, err := io.ReadAll(io.LimitReader(r.Body, s.cfg.TunnelMaxBody+1))
	_ = r.Body.Close()
	if err != nil {
		writeErr(w, http.StatusBadRequest, "body_read_failed")
		return
	}
	if int64(len(body)) > s.cfg.TunnelMaxBody {
		writeErr(w, http.StatusRequestEntityTooLarge, "body_too_large")
		return
	}

	path := "/" + strings.TrimPrefix(r.PathValue("path"), "/")
	if r.URL.RawQuery != "" {
		path += "?" + r.URL.RawQuery
	}

	requestID := "http_" + randomHex(12)
	responseCh := make(chan httpTunnelResponse, 1)
	dc.registerHTTP(requestID, responseCh)
	defer dc.unregisterHTTP(requestID)

	msg := httpTunnelRequest{
		Type:   "http_request",
		ID:     requestID,
		Method: r.Method,
		Path:   path,
		Headers: map[string]string{
			"accept":       r.Header.Get("Accept"),
			"content-type": r.Header.Get("Content-Type"),
		},
		Body: base64.StdEncoding.EncodeToString(body),
	}

	ctx, cancel := context.WithTimeout(r.Context(), s.cfg.WriteTimeout)
	err = dc.writeJSON(ctx, msg)
	cancel()
	if err != nil {
		writeErr(w, http.StatusBadGateway, "device_write_failed")
		return
	}

	select {
	case response := <-responseCh:
		if response.Error != "" {
			writeErr(w, http.StatusBadGateway, response.Error)
			return
		}
		payload, err := base64.StdEncoding.DecodeString(response.Body)
		if err != nil {
			writeErr(w, http.StatusBadGateway, "bad_device_response")
			return
		}
		status := response.Status
		if status < 100 || status > 599 {
			status = http.StatusBadGateway
		}
		if response.ContentType != "" {
			w.Header().Set("Content-Type", response.ContentType)
		}
		w.WriteHeader(status)
		_, _ = w.Write(payload)
	case <-time.After(s.cfg.TunnelTimeout):
		writeErr(w, http.StatusGatewayTimeout, "device_timeout")
	case <-r.Context().Done():
		return
	}
}
