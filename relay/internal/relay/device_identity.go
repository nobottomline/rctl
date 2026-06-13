package relay

import "strings"

const (
	maxDeviceIDLength   = 80
	maxDeviceNameLength = 120
)

func normalizeDeviceID(id string) (string, bool) {
	id = strings.TrimSpace(id)
	if id == "" {
		return randomHex(16), true
	}
	if len(id) > maxDeviceIDLength {
		return "", false
	}
	for _, r := range id {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '.' || r == '_' || r == '-' {
			continue
		}
		return "", false
	}
	return id, true
}

func normalizeDeviceName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		name = "Unnamed device"
	}
	if len([]rune(name)) <= maxDeviceNameLength {
		return name
	}
	return string([]rune(name)[:maxDeviceNameLength])
}
