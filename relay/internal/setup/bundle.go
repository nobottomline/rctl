package setup

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"sort"
	"strings"
)

type Secrets struct {
	Admin   string
	Session string
	TURN    string
}

type File struct {
	Path    string
	Mode    uint32
	Content []byte
	Secret  bool
}

type Bundle struct {
	Files   []File
	Secrets Secrets
}

func GenerateSecrets(source io.Reader) (Secrets, error) {
	if source == nil {
		source = rand.Reader
	}
	admin, err := randomToken(source, 48)
	if err != nil {
		return Secrets{}, err
	}
	session, err := randomToken(source, 48)
	if err != nil {
		return Secrets{}, err
	}
	turnRaw := make([]byte, 32)
	if _, err := io.ReadFull(source, turnRaw); err != nil {
		return Secrets{}, fmt.Errorf("generate TURN secret: %w", err)
	}
	return Secrets{Admin: admin, Session: session, TURN: hex.EncodeToString(turnRaw)}, nil
}

func randomToken(source io.Reader, size int) (string, error) {
	raw := make([]byte, size)
	if _, err := io.ReadFull(source, raw); err != nil {
		return "", fmt.Errorf("generate secret: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

func RenderDedicatedBundle(cfg Config, secrets Secrets) (Bundle, error) {
	return RenderDedicatedBundleAt(cfg, secrets, DefaultPaths())
}

func RenderDedicatedBundleAt(cfg Config, secrets Secrets, paths Paths) (Bundle, error) {
	if err := cfg.Validate(); err != nil {
		return Bundle{}, err
	}
	if cfg.Profile != ProfileContainer {
		return Bundle{}, errors.New("dedicated bundle requires the container profile")
	}
	if len(secrets.Admin) < 48 || len(secrets.Session) < 48 || (cfg.EnableTURN && len(secrets.TURN) < 64) {
		return Bundle{}, errors.New("generated secrets are missing or too short")
	}
	for _, value := range []string{secrets.Admin, secrets.Session, secrets.TURN} {
		if strings.ContainsAny(value, "\r\n\x00") {
			return Bundle{}, errors.New("secret contains an invalid character")
		}
	}
	origin, _ := ParsePublicOrigin(cfg.PublicURL)
	if origin.Port() != "" && origin.Port() != "443" {
		return Bundle{}, errors.New("dedicated container profile requires the standard HTTPS port 443")
	}
	host := origin.Hostname()

	env := map[string]string{
		"RCTL_RELAY_LISTEN":               ":8080",
		"RCTL_RELAY_PUBLIC_URL":           strings.TrimSuffix(cfg.PublicURL, "/"),
		"RCTL_RELAY_DB":                   "/data/rctl-relay.db",
		"RCTL_RELAY_WEB_DIR":              "/app/web",
		"RCTL_RELAY_ADMIN_SECRET":         secrets.Admin,
		"RCTL_RELAY_SESSION_SECRET":       secrets.Session,
		"RCTL_RELAY_ENROLL_TTL":           "30m",
		"RCTL_RELAY_TRUST_PROXY_HEADERS":  "1",
		"RCTL_RELAY_TRUSTED_PROXY_DEPTH":  "1",
		"RCTL_RELAY_LOGIN_MAX":            "5",
		"RCTL_RELAY_LOGIN_WINDOW":         "1m",
		"RCTL_RELAY_ADMIN_MAX":            "60",
		"RCTL_RELAY_ADMIN_WINDOW":         "1m",
		"RCTL_RELAY_DEVICE_MAX":           "20",
		"RCTL_RELAY_DEVICE_WINDOW":        "1m",
		"RCTL_RELAY_TUNNEL_MAX":           "240",
		"RCTL_RELAY_TUNNEL_WINDOW":        "1m",
		"RCTL_RELAY_TUNNEL_TIMEOUT":       "20s",
		"RCTL_RELAY_TUNNEL_MAX_BODY":      "2097152",
		"RCTL_RELAY_STREAM_START_TIMEOUT": "20s",
		"RCTL_RELAY_ALLOW_INSECURE":       "0",
		"RCTL_RELAY_ENABLE_WEBRTC":        "1",
	}
	if cfg.EnableTURN {
		env["RCTL_RELAY_TURN_SECRET"] = secrets.TURN
		env["RCTL_RELAY_TURN_URLS"] = "turn:" + host + ":3478?transport=udp,turn:" + host + ":3478?transport=tcp"
		env["RCTL_RELAY_STUN_URLS"] = "stun:" + host + ":3478"
		env["RCTL_RELAY_TURN_TTL"] = "1h"
	}
	if cfg.DevicePackages {
		env["RCTL_RELAY_PUBLIC_PACKAGE"] = "/packages/rctl-public.deb"
	}
	if cfg.UpdateManifestURL != "" {
		env["RCTL_RELAY_UPDATE_MANIFEST_URL"] = cfg.UpdateManifestURL
		if semanticVersionPattern.MatchString(cfg.Release) {
			env["RCTL_RELAY_UPDATE_TARGET_VERSION"] = cfg.Release
		}
	}

	compose, err := renderCompose(cfg, paths)
	if err != nil {
		return Bundle{}, err
	}
	files := []File{
		{Path: paths.RelayEnv, Mode: 0o600, Content: renderEnv(env), Secret: true},
		{Path: paths.Compose, Mode: 0o644, Content: compose},
		{Path: paths.Caddyfile, Mode: 0o644, Content: renderCaddyfile(origin, cfg.ACMEEmail)},
	}
	if cfg.EnableTURN {
		files = append(files, File{Path: paths.Coturn, Mode: 0o600, Content: renderCoturn(cfg, host, secrets.TURN), Secret: true})
	}
	return Bundle{Files: files, Secrets: secrets}, nil
}

func renderEnv(values map[string]string) []byte {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var out strings.Builder
	for _, key := range keys {
		fmt.Fprintf(&out, "%s=%s\n", key, values[key])
	}
	return []byte(out.String())
}

func renderCompose(cfg Config, paths Paths) ([]byte, error) {
	type logging struct {
		Driver  string            `json:"driver"`
		Options map[string]string `json:"options"`
	}
	boundedLogs := logging{Driver: "json-file", Options: map[string]string{"max-file": "3", "max-size": "10m"}}
	services := map[string]any{
		"relay": map[string]any{
			"image": cfg.RelayImage, "restart": "unless-stopped", "env_file": []string{paths.RelayEnv},
			"volumes": []string{paths.RelayDataDir + ":/data"}, "networks": []string{"backend"},
			"read_only": true, "tmpfs": []string{"/tmp:size=64m,mode=1777"}, "cap_drop": []string{"ALL"},
			"security_opt": []string{"no-new-privileges:true"}, "stop_grace_period": "20s", "logging": boundedLogs, "pids_limit": 256, "init": true,
			"healthcheck": map[string]any{"test": []string{"CMD", "/usr/local/bin/rctl-relay", "healthcheck", "http://127.0.0.1:8080/healthz"}, "interval": "15s", "timeout": "5s", "retries": 4, "start_period": "10s"},
		},
		"caddy": map[string]any{
			"image": cfg.CaddyImage, "restart": "unless-stopped", "depends_on": map[string]any{"relay": map[string]string{"condition": "service_healthy"}},
			"ports":    []string{"80:80", "443:443", "443:443/udp"},
			"volumes":  []string{paths.Caddyfile + ":/etc/caddy/Caddyfile:ro", paths.CaddyDataDir + ":/data", paths.CaddyConfDir + ":/config"},
			"networks": []string{"edge", "backend"}, "read_only": true, "tmpfs": []string{"/tmp:size=64m,mode=1777"},
			"security_opt": []string{"no-new-privileges:true"}, "logging": boundedLogs, "cap_drop": []string{"ALL"}, "cap_add": []string{"NET_BIND_SERVICE"}, "pids_limit": 128, "init": true,
		},
	}
	if cfg.DevicePackages {
		relay := services["relay"].(map[string]any)
		relay["volumes"] = append(relay["volumes"].([]string), paths.PublicPackage+":/packages/rctl-public.deb:ro")
	}
	if cfg.EnableTURN {
		services["coturn"] = map[string]any{
			"image": cfg.CoturnImage, "restart": "unless-stopped", "network_mode": "host", "read_only": true,
			"volumes": []string{paths.Coturn + ":/etc/coturn/turnserver.conf:ro"},
			"command": []string{"-c", "/etc/coturn/turnserver.conf"}, "tmpfs": []string{"/tmp:size=32m,mode=1777"},
			"security_opt": []string{"no-new-privileges:true"}, "logging": boundedLogs, "cap_drop": []string{"ALL"}, "cap_add": []string{"NET_BIND_SERVICE"}, "pids_limit": 256, "init": true,
			"healthcheck": map[string]any{"test": []string{"CMD", "turnutils_stunclient", "-p", "3478", "-t", "1000", "127.0.0.1"}, "interval": "15s", "timeout": "5s", "retries": 4, "start_period": "5s"},
		}
	}
	document := map[string]any{
		"name": "rctl", "services": services,
		"networks": map[string]any{"edge": map[string]any{}, "backend": map[string]any{"internal": true}},
	}
	var out bytes.Buffer
	enc := json.NewEncoder(&out)
	enc.SetIndent("", "  ")
	if err := enc.Encode(document); err != nil {
		return nil, fmt.Errorf("encode compose: %w", err)
	}
	return out.Bytes(), nil
}

func renderCaddyfile(origin *url.URL, email string) []byte {
	var out strings.Builder
	out.WriteString("{\n\tadmin off\n")
	if email != "" {
		fmt.Fprintf(&out, "\temail %s\n", email)
	}
	out.WriteString("}\n\n")
	fmt.Fprintf(&out, "%s {\n", origin.Host)
	out.WriteString("\theader {\n\t\tStrict-Transport-Security \"max-age=31536000\"\n\t\tX-Content-Type-Options \"nosniff\"\n\t\tReferrer-Policy \"no-referrer\"\n\t\t-Server\n\t}\n")
	out.WriteString("\treverse_proxy relay:8080 {\n\t\theader_up X-Forwarded-For {remote_host}\n\t\theader_up X-Real-IP {remote_host}\n\t\theader_up X-Forwarded-Proto {scheme}\n\t\theader_up X-Forwarded-Host {host}\n\t}\n}\n")
	return []byte(out.String())
}

func renderCoturn(cfg Config, realm, secret string) []byte {
	lines := []string{
		"listening-port=3478", "listening-ip=0.0.0.0", "external-ip=" + net.ParseIP(cfg.TURNExternalIP).String(),
		"realm=" + realm, "server-name=" + realm, "fingerprint", "use-auth-secret", "static-auth-secret=" + secret,
		"min-port=49160", "max-port=49260", "no-tls", "no-multicast-peers", "stale-nonce=600", "total-quota=100",
		"denied-peer-ip=0.0.0.0-0.255.255.255", "denied-peer-ip=10.0.0.0-10.255.255.255",
		"denied-peer-ip=100.64.0.0-100.127.255.255", "denied-peer-ip=127.0.0.0-127.255.255.255",
		"denied-peer-ip=169.254.0.0-169.254.255.255", "denied-peer-ip=172.16.0.0-172.31.255.255",
		"denied-peer-ip=192.168.0.0-192.168.255.255", "denied-peer-ip=::1",
	}
	return []byte(strings.Join(lines, "\n") + "\n")
}
