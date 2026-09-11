package relay

import (
	"encoding/json"
	"errors"
	"io"
	"math"
	"net"
	"net/http"
	"regexp"
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

type fieldKind int

const (
	kindString fieldKind = iota
	kindNumber           // non-negative integer
	kindBool             // JSON boolean ("true"/"false" strings from older clients are accepted)
	kindList             // list of short lowercase tokens, e.g. capabilities
	kindIP               // IPv4/IPv6 literal
)

type clientField struct {
	kind     fieldKind
	maxRunes int // strings: per value; lists: per token
	maxItems int // lists
}

// Identity and capabilities: what this controller is and what this build of the
// app can do. Reported after pairing and on change.
var controllerClientFields = map[string]clientField{
	"schema_version":  {kind: kindNumber},               // profile schema, for forward compatibility
	"protocol_major":  {kind: kindNumber},               // wire protocol the app speaks
	"model":           {kind: kindString, maxRunes: 64}, // hardware identifier, e.g. iPhone15,2
	"model_name":      {kind: kindString, maxRunes: 80}, // marketing name, e.g. iPhone 14 Pro
	"idiom":           {kind: kindString, maxRunes: 16}, // phone | pad
	"system_name":     {kind: kindString, maxRunes: 32}, // iOS | iPadOS
	"system_version":  {kind: kindString, maxRunes: 32},
	"os_build":        {kind: kindString, maxRunes: 32},
	"app_version":     {kind: kindString, maxRunes: 32},
	"app_build":       {kind: kindString, maxRunes: 32},
	"bundle_id":       {kind: kindString, maxRunes: 128},
	"install_channel": {kind: kindString, maxRunes: 24}, // appstore | testflight | debug | adhoc | enterprise
	"device_name":     {kind: kindString, maxRunes: 80},
	"locale":          {kind: kindString, maxRunes: 32},
	"language":        {kind: kindString, maxRunes: 32},
	"timezone":        {kind: kindString, maxRunes: 64},
	"screen":          {kind: kindString, maxRunes: 48}, // e.g. 393×852 @3x
	"cpu_count":       {kind: kindNumber},
	"memory_bytes":    {kind: kindNumber},
	"disk_bytes":      {kind: kindNumber},
	"capabilities":    {kind: kindList, maxRunes: 32, maxItems: 32}, // what this app build supports
}

// Condition: what is going on with the phone right now. Carried by the
// foreground heartbeat.
var controllerTelemetryFields = map[string]clientField{
	"battery_level":          {kind: kindNumber},               // percent 0..100
	"battery_state":          {kind: kindString, maxRunes: 16}, // unplugged | charging | full | unknown
	"low_power":              {kind: kindBool},
	"thermal":                {kind: kindString, maxRunes: 16}, // nominal | fair | serious | critical
	"network":                {kind: kindString, maxRunes: 16}, // wifi | cellular | wired | none | unknown
	"network_expensive":      {kind: kindBool},                 // NWPath.isExpensive (hotspot / cellular)
	"network_constrained":    {kind: kindBool},                 // NWPath.isConstrained (Low Data Mode)
	"lan_ip":                 {kind: kindIP},                   // private address on the local network
	"disk_free_bytes":        {kind: kindNumber},
	"memory_available_bytes": {kind: kindNumber}, // memory the app may still allocate
	"uptime_seconds":         {kind: kindNumber}, // since the phone booted
}

var listToken = regexp.MustCompile(`^[a-z0-9][a-z0-9_.:-]*$`)

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
		if !ok || raw == nil { // unknown keys are dropped; explicit null clears
			continue
		}
		value, err := sanitizeClientValue(key, raw, spec)
		if err != nil {
			return "", err
		}
		if value != nil {
			out[key] = value
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

func sanitizeClientValue(key string, raw any, spec clientField) (any, error) {
	switch spec.kind {
	case kindString:
		value, ok := raw.(string)
		if !ok {
			return nil, errors.New("expected string for " + key)
		}
		return boundedClientString(key, value, spec.maxRunes)
	case kindNumber:
		value, ok := raw.(float64)
		if !ok || math.IsNaN(value) || math.IsInf(value, 0) || value < 0 || value > 1<<53 || value != math.Trunc(value) {
			return nil, errors.New("invalid number for " + key)
		}
		return int64(value), nil
	case kindBool:
		switch value := raw.(type) {
		case bool:
			return value, nil
		case string: // first-generation clients sent "true"/"false"
			if value == "true" || value == "false" {
				return value == "true", nil
			}
		}
		return nil, errors.New("expected boolean for " + key)
	case kindList:
		items, ok := raw.([]any)
		if !ok || len(items) > spec.maxItems {
			return nil, errors.New("invalid list for " + key)
		}
		seen := make(map[string]struct{}, len(items))
		tokens := make([]string, 0, len(items))
		for _, item := range items {
			token, ok := item.(string)
			if !ok || utf8.RuneCountInString(token) > spec.maxRunes || !listToken.MatchString(token) {
				return nil, errors.New("invalid token in " + key)
			}
			if _, dup := seen[token]; dup {
				continue
			}
			seen[token] = struct{}{}
			tokens = append(tokens, token)
		}
		sort.Strings(tokens)
		if len(tokens) == 0 {
			return nil, nil
		}
		return tokens, nil
	case kindIP:
		value, ok := raw.(string)
		if !ok {
			return nil, errors.New("expected string for " + key)
		}
		value = strings.TrimSpace(value)
		if value == "" {
			return nil, nil
		}
		ip := net.ParseIP(value)
		if ip == nil {
			return nil, errors.New("invalid ip for " + key)
		}
		return ip.String(), nil
	}
	return nil, errors.New("unsupported field " + key)
}

func boundedClientString(key, value string, maxRunes int) (any, error) {
	value = strings.TrimSpace(value)
	if !utf8.ValidString(value) || strings.ContainsAny(value, "\x00\r\n\t") {
		return nil, errors.New("invalid string for " + key)
	}
	if utf8.RuneCountInString(value) > maxRunes {
		return nil, errors.New("value too long for " + key)
	}
	if value == "" {
		return nil, nil
	}
	return value, nil
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
