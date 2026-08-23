package relay

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"time"
)

func (s *server) deviceHTTP(ctx context.Context, dc *deviceConn, method, path string, body []byte) (httpTunnelResponse, error) {
	requestID := "http_" + randomHex(12)
	responseCh := make(chan httpTunnelResponse, 1)
	dc.registerHTTP(requestID, responseCh)
	defer dc.unregisterHTTP(requestID)
	request := httpTunnelRequest{
		Type: "http_request", ID: requestID, Method: method, Path: path,
		Headers: map[string]string{"accept": "application/json", "content-type": "application/json"},
		Body:    base64.StdEncoding.EncodeToString(body),
	}
	writeCtx, cancel := context.WithTimeout(ctx, s.cfg.WriteTimeout)
	err := dc.writeJSON(writeCtx, request)
	cancel()
	if err != nil {
		return httpTunnelResponse{}, err
	}
	select {
	case response := <-responseCh:
		if response.Error != "" {
			return response, errors.New(response.Error)
		}
		return response, nil
	case <-time.After(s.cfg.TunnelTimeout):
		return httpTunnelResponse{}, errors.New("device timeout")
	case <-ctx.Done():
		return httpTunnelResponse{}, ctx.Err()
	}
}

func decodeDeviceJSON(response httpTunnelResponse, destination any) error {
	if response.Status < 200 || response.Status >= 300 {
		return errors.New("device rejected request")
	}
	raw, err := base64.StdEncoding.DecodeString(response.Body)
	if err != nil {
		return err
	}
	return json.Unmarshal(raw, destination)
}

func (s *server) handleUpdateDevice(w http.ResponseWriter, r *http.Request) {
	if s.cfg.UpdateManifestURL == "" {
		writeErr(w, http.StatusServiceUnavailable, "update_manifest_not_configured")
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
	if !hasFeature(dc.features, "update.transactional") {
		writeErr(w, http.StatusConflict, "device_updater_not_supported")
		return
	}
	if s.cfg.UpdateTargetVersion != "" && dc.daemonVersion == s.cfg.UpdateTargetVersion {
		writeErr(w, http.StatusConflict, "device_already_current")
		return
	}
	var compatibilityError string
	_ = s.db.QueryRowContext(r.Context(), `SELECT COALESCE(compatibility_error, '') FROM devices WHERE id=?`, deviceID).Scan(&compatibilityError)
	if compatibilityError != "" {
		writeErr(w, http.StatusConflict, compatibilityError)
		return
	}

	confirmationBody, _ := json.Marshal(map[string]string{
		"action": "device_update", "target": s.cfg.UpdateManifestURL,
	})
	confirmationResponse, err := s.deviceHTTP(r.Context(), dc, http.MethodPost, "/v1/confirmation", confirmationBody)
	var confirmation struct {
		Token string `json:"token"`
	}
	if err != nil || decodeDeviceJSON(confirmationResponse, &confirmation) != nil || confirmation.Token == "" {
		writeErr(w, http.StatusBadGateway, "device_confirmation_failed")
		return
	}
	updateBody, _ := json.Marshal(map[string]string{
		"token": confirmation.Token, "manifest_url": s.cfg.UpdateManifestURL,
	})
	updateResponse, err := s.deviceHTTP(r.Context(), dc, http.MethodPost, "/v1/update", updateBody)
	var result map[string]any
	if err != nil || decodeDeviceJSON(updateResponse, &result) != nil {
		writeErr(w, http.StatusBadGateway, "device_update_start_failed")
		return
	}
	s.audit(r, "admin_device_update_started", "device_id", deviceID, "job_id", result["job_id"])
	writeJSON(w, http.StatusAccepted, result)
}

func hasFeature(features []string, wanted string) bool {
	for _, feature := range features {
		if feature == wanted {
			return true
		}
	}
	return false
}
