package relay

import (
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// The controller app describes itself once after pairing and again only when
// something changes (an OS or app update). The relay stores exactly the keys it
// knows, bounded in size, so a client cannot turn the controllers table into a
// blob store or smuggle markup into the admin console. Unknown keys are dropped
// rather than rejected so a newer app keeps working against an older relay.
const (
	controllerClientBodyMax   = 8 << 10
	controllerClientMaxFields = 32
)

type clientField struct {
	maxRunes int  // for strings
	number   bool // non-negative integer
}

var controllerClientFields = map[string]clientField{
	"model":           {maxRunes: 64}, // hardware identifier, e.g. iPhone15,2
	"model_name":      {maxRunes: 80}, // marketing name, e.g. iPhone 14 Pro
	"idiom":           {maxRunes: 16}, // phone | pad
	"system_name":     {maxRunes: 32}, // iOS | iPadOS
	"system_version":  {maxRunes: 32},
	"os_build":        {maxRunes: 32},
	"app_version":     {maxRunes: 32},
	"app_build":       {maxRunes: 32},
	"bundle_id":       {maxRunes: 128},
	"device_name":     {maxRunes: 80},
	"locale":          {maxRunes: 32},
	"language":        {maxRunes: 32},
	"timezone":        {maxRunes: 64},
	"screen":          {maxRunes: 48}, // e.g. 393×852 @3x
	"cpu_count":       {number: true},
	"memory_bytes":    {number: true},
	"disk_bytes":      {number: true},
	"disk_free_bytes": {number: true},
}

var controllerTelemetryFields = map[string]clientField{
	"battery_level":   {number: true}, // percent 0..100
	"battery_state":   {maxRunes: 16}, // unplugged | charging | full | unknown
	"low_power":       {maxRunes: 5},  // "true" | "false" (kept as string for a single validator)
	"thermal":         {maxRunes: 16}, // nominal | fair | serious | critical
	"network":         {maxRunes: 16}, // wifi | cellular | wired | none | unknown
	"disk_free_bytes": {number: true},
}

type controllerClientRequest struct {
	Client map[string]any `json:"client"`
}

type controllerPresenceRequest struct {
	Telemetry map[string]any `json:"telemetry"`
}

// sanitizeClientFields keeps known keys with valid, bounded values; returns the
// canonical JSON (sorted keys) or an error when a known key carries garbage.
func sanitizeClientFields(input map[string]any, allowed map[string]clientField) (string, error) {
	if len(input) > controllerClientMaxFields {
		return "", errors.New("too many fields")
	}
	out := make(map[string]any, len(input))
	for key, raw := range input {
		spec, ok := allowed[key]
		if !ok {
			continue
		}
		switch value := raw.(type) {
		case string:
			if spec.number {
				return "", errors.New("expected number for " + key)
			}
			value = strings.TrimSpace(value)
			if !utf8.ValidString(value) || strings.ContainsAny(value, "\x00\r\n\t") {
				return "", errors.New("invalid string for " + key)
			}
			if utf8.RuneCountInString(value) > spec.maxRunes {
				return "", errors.New("value too long for " + key)
			}
			if value != "" {
				out[key] = value
			}
		case float64:
			if !spec.number || math.IsNaN(value) || math.IsInf(value, 0) || value < 0 || value > 1<<53 || value != math.Trunc(value) {
				return "", errors.New("invalid number for " + key)
			}
			out[key] = int64(value)
		case bool:
			if spec.number || spec.maxRunes < 5 {
				return "", errors.New("invalid boolean for " + key)
			}
			if value {
				out[key] = "true"
			} else {
				out[key] = "false"
			}
		case nil:
			// Explicit null clears the field: simply omitted.
		default:
			return "", errors.New("unsupported value for " + key)
		}
	}
	if len(out) == 0 {
		return "", nil
	}
	keys := make([]string, 0, len(out))
	for key := range out {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	ordered := make([]string, 0, len(keys))
	for _, key := range keys {
		encoded, err := json.Marshal(out[key])
		if err != nil {
			return "", err
		}
		name, _ := json.Marshal(key)
		ordered = append(ordered, string(name)+":"+string(encoded))
	}
	return "{" + strings.Join(ordered, ",") + "}", nil
}

func (s *server) handleUpdateControllerClient(w http.ResponseWriter, r *http.Request) {
	principal, ok := controllerFromContext(r.Context())
	if !ok {
		writeErr(w, http.StatusUnauthorized, "controller_unauthorized")
		return
	}
	var req controllerClientRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, controllerClientBodyMax)).Decode(&req); err != nil || req.Client == nil {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}
	clientJSON, err := sanitizeClientFields(req.Client, controllerClientFields)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_client")
		return
	}
	now := time.Now()
	res, err := s.db.ExecContext(r.Context(), `
UPDATE controllers SET client_json=?, client_updated_at=?, last_ip=?, user_agent=?
WHERE id=? AND status='active'`, nullIfEmpty(clientJSON), now.Unix(), s.clientIP(r), boundedUserAgent(r), principal.ControllerID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "client_update_failed")
		return
	}
	if n, _ := res.RowsAffected(); n != 1 {
		writeErr(w, http.StatusUnauthorized, "controller_unauthorized")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	s.audit(r, "controller_client_updated", "controller_id", principal.ControllerID)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// readControllerTelemetry parses the optional presence body. Returns nil JSON for
// an absent/empty body (legacy heartbeat) and an error for a malformed one.
func readControllerTelemetry(r *http.Request) (any, error) {
	body, err := io.ReadAll(io.LimitReader(r.Body, controllerClientBodyMax+1))
	if err != nil {
		return nil, err
	}
	if len(strings.TrimSpace(string(body))) == 0 {
		return nil, nil
	}
	if len(body) > controllerClientBodyMax {
		return nil, errors.New("telemetry too large")
	}
	var req controllerPresenceRequest
	if err := json.Unmarshal(body, &req); err != nil {
		return nil, err
	}
	if req.Telemetry == nil {
		return nil, nil
	}
	telemetryJSON, err := sanitizeClientFields(req.Telemetry, controllerTelemetryFields)
	if err != nil {
		return nil, err
	}
	return nullIfEmpty(telemetryJSON), nil
}

// boundedUserAgent is the request User-Agent capped like the session one.
func boundedUserAgent(r *http.Request) string {
	ua := r.UserAgent()
	if len(ua) > 200 {
		ua = ua[:200]
	}
	return ua
}
