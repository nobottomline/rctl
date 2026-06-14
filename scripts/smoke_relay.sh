#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${RCTL_RELAY_SMOKE_PORT:-18091}"
BASE_URL="http://127.0.0.1:${PORT}"
WORK="$(mktemp -d "${TMPDIR:-/private/tmp}/rctl-relay-smoke.XXXXXX")"
RELAY_PID=""
DEVICE_PID=""

cleanup() {
  local status="$?"
  if [[ "${status}" -ne 0 ]]; then
    printf '\nrelay smoke failed with status %s\n' "${status}" >&2
    if [[ -f "${WORK}/relay.log" ]]; then
      printf '\n--- relay.log ---\n' >&2
      cat "${WORK}/relay.log" >&2
    fi
    if [[ -f "${WORK}/device.log" ]]; then
      printf '\n--- device.log ---\n' >&2
      cat "${WORK}/device.log" >&2
    fi
  fi
  if [[ -n "${DEVICE_PID}" ]] && kill -0 "${DEVICE_PID}" 2>/dev/null; then
    kill "${DEVICE_PID}" 2>/dev/null || true
    wait "${DEVICE_PID}" 2>/dev/null || true
  fi
  if [[ -n "${RELAY_PID}" ]] && kill -0 "${RELAY_PID}" 2>/dev/null; then
    kill "${RELAY_PID}" 2>/dev/null || true
    wait "${RELAY_PID}" 2>/dev/null || true
  fi
  rm -rf "${WORK}"
  exit "${status}"
}
trap cleanup EXIT

say() {
  printf '==> %s\n' "$*"
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

extract_json_string() {
  local key="$1"
  sed -n "s/.*\"${key}\":\"\\([^\"]*\\)\".*/\\1/p"
}

require curl
require go

say "building relay binary"
(
  cd "${ROOT}/relay"
  go build -o "${WORK}/rctl-relay" ./cmd/rctl-relay
)

cat > "${WORK}/device.go" <<'GO'
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"

	"nhooyr.io/websocket"
)

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	token := os.Getenv("TOKEN")
	url := os.Getenv("DEVICE_WS_URL")
	deviceID := os.Getenv("DEVICE_ID")
	if token == "" || url == "" || deviceID == "" {
		panic("TOKEN, DEVICE_WS_URL, and DEVICE_ID are required")
	}

	header := http.Header{}
	header.Set("Authorization", "Bearer "+token)
	ws, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPHeader: header})
	if err != nil {
		panic(err)
	}
	defer ws.Close(websocket.StatusNormalClosure, "")

	writeJSON(ctx, ws, map[string]any{
		"type":        "hello",
		"device_id":   deviceID,
		"device_name": "Smoke Device",
	})

	for {
		_, payload, err := ws.Read(ctx)
		if err != nil {
			return
		}
		var msg map[string]any
		if json.Unmarshal(payload, &msg) != nil {
			continue
		}
		switch msg["type"] {
		case "http_request":
			id, _ := msg["id"].(string)
			path, _ := msg["path"].(string)
			body := base64.StdEncoding.EncodeToString([]byte("tunnel-ok:" + path))
			writeJSON(ctx, ws, map[string]any{
				"type":         "http_response",
				"id":           id,
				"status":       200,
				"content_type": "text/plain; charset=utf-8",
				"body":         body,
			})
		case "stream_open":
			id, _ := msg["id"].(string)
			streamURL, _ := msg["stream_url"].(string)
			if streamURL != "" {
				streamHeader := http.Header{}
				streamHeader.Set("Authorization", "Bearer "+token)
				streamWS, _, err := websocket.Dial(ctx, streamURL, &websocket.DialOptions{HTTPHeader: streamHeader})
				if err != nil {
					panic(err)
				}
				writeJSON(ctx, streamWS, map[string]any{
					"type":         "stream_start",
					"id":           id,
					"status":       200,
					"content_type": "text/plain; charset=utf-8",
				})
				for _, chunk := range []string{"one\n", "two\n", "three\n"} {
					if err := streamWS.Write(ctx, websocket.MessageBinary, []byte(chunk)); err != nil {
						panic(err)
					}
				}
				writeJSON(ctx, streamWS, map[string]any{"type": "stream_end", "id": id})
				streamWS.Close(websocket.StatusNormalClosure, "")
				continue
			}
			writeJSON(ctx, ws, map[string]any{
				"type":         "stream_start",
				"id":           id,
				"status":       200,
				"content_type": "text/plain; charset=utf-8",
			})
			for _, chunk := range []string{"one\n", "two\n", "three\n"} {
				writeJSON(ctx, ws, map[string]any{
					"type": "stream_chunk",
					"id":   id,
					"body": base64.StdEncoding.EncodeToString([]byte(chunk)),
				})
			}
			writeJSON(ctx, ws, map[string]any{"type": "stream_end", "id": id})
		case "approved":
			if secret, _ := msg["device_secret"].(string); secret != "" {
				token = secret
			}
		case "stream_cancel", "hello_ack":
		case "term_open":
			id, _ := msg["id"].(string)
			body := base64.StdEncoding.EncodeToString([]byte("term-ok\n"))
			writeJSON(ctx, ws, map[string]any{"type": "term_data", "id": id, "body": body})
		case "term_input":
		case "term_cancel":
		default:
			fmt.Fprintf(os.Stderr, "ignored message type %v\n", msg["type"])
		}
	}
}

func writeJSON(ctx context.Context, ws *websocket.Conn, v any) {
	payload, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	if err := ws.Write(ctx, websocket.MessageText, payload); err != nil {
		panic(err)
	}
}
GO

cat > "${WORK}/term_client.go" <<'GO'
package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"nhooyr.io/websocket"
)

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	url := os.Getenv("TERM_WS_URL")
	cookieFile := os.Getenv("COOKIE_FILE")
	if url == "" || cookieFile == "" {
		panic("TERM_WS_URL and COOKIE_FILE are required")
	}
	cookieValue := readCookie(cookieFile, "rctl_session")
	if cookieValue == "" {
		panic("missing rctl_session cookie")
	}
	header := http.Header{}
	header.Set("Cookie", "rctl_session="+cookieValue)
	ws, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPHeader: header})
	if err != nil {
		panic(err)
	}
	defer ws.Close(websocket.StatusNormalClosure, "")
	_, payload, err := ws.Read(ctx)
	if err != nil {
		panic(err)
	}
	if string(payload) != "term-ok\n" {
		panic(fmt.Sprintf("unexpected terminal payload %q", string(payload)))
	}
}

func readCookie(path, name string) string {
	raw, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	for _, line := range strings.Split(string(raw), "\n") {
		if strings.TrimSpace(line) == "" || (strings.HasPrefix(line, "#") && !strings.HasPrefix(line, "#HttpOnly_")) {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 7 && fields[5] == name {
			return fields[6]
		}
	}
	return ""
}
GO

say "starting relay on ${BASE_URL}"
RCTL_RELAY_LISTEN="127.0.0.1:${PORT}" \
RCTL_RELAY_PUBLIC_URL="${BASE_URL}" \
RCTL_RELAY_ALLOW_INSECURE=1 \
RCTL_RELAY_DB="${WORK}/relay.db" \
RCTL_RELAY_WEB_DIR="${ROOT}/web" \
RCTL_RELAY_ADMIN_SECRET="admin-secret-0123456789abcdef" \
RCTL_RELAY_SESSION_SECRET="session-secret-0123456789abcdef0123456789" \
RCTL_RELAY_TUNNEL_TIMEOUT=5s \
RCTL_RELAY_STREAM_START_TIMEOUT=5s \
"${WORK}/rctl-relay" >"${WORK}/relay.log" 2>&1 &
RELAY_PID="$!"

for _ in {1..50}; do
  if curl -fsS "${BASE_URL}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
curl -fsS "${BASE_URL}/healthz" >/dev/null

say "logging in and creating enrollment"
curl -fsS -c "${WORK}/admin.cookies" \
  -H 'Content-Type: application/json' \
  -d '{"secret":"admin-secret-0123456789abcdef"}' \
  "${BASE_URL}/api/admin/login" >/dev/null

curl -fsS -b "${WORK}/admin.cookies" \
  -X POST "${BASE_URL}/api/admin/enrollments" >"${WORK}/enrollment.json"
TOKEN="$(extract_json_string token <"${WORK}/enrollment.json")"
[[ -n "${TOKEN}" ]] || {
  printf 'failed to parse enrollment token\n' >&2
  cat "${WORK}/enrollment.json" >&2
  exit 1
}

say "connecting synthetic device"
(
  cd "${ROOT}/relay"
  TOKEN="${TOKEN}" \
  DEVICE_WS_URL="ws://127.0.0.1:${PORT}/device" \
  DEVICE_ID="smoke-device" \
  go run "${WORK}/device.go"
) >"${WORK}/device.log" 2>&1 &
DEVICE_PID="$!"

for _ in {1..50}; do
  if curl -fsS -b "${WORK}/admin.cookies" "${BASE_URL}/api/admin/devices" | grep -q '"id":"smoke-device"'; then
    break
  fi
  sleep 0.1
done
curl -fsS -b "${WORK}/admin.cookies" "${BASE_URL}/api/admin/devices" >"${WORK}/devices-pending.json"
grep -q '"status":"pending"' "${WORK}/devices-pending.json"

say "approving device"
curl -fsS -b "${WORK}/admin.cookies" \
  -X POST "${BASE_URL}/api/admin/devices/smoke-device/approve" >/dev/null
curl -fsS -b "${WORK}/admin.cookies" "${BASE_URL}/api/admin/devices" >"${WORK}/devices-approved.json"
grep -q '"status":"approved"' "${WORK}/devices-approved.json"

say "checking relay-hosted control page"
curl -fsS -b "${WORK}/admin.cookies" \
  "${BASE_URL}/control/devices/smoke-device" >"${WORK}/control.html"
grep -q 'RCTL_PROXY_BASE="/proxy/devices/smoke-device"' "${WORK}/control.html"
grep -q 'RCTL_STREAM_BASE="/stream/devices/smoke-device"' "${WORK}/control.html"
curl -fsSI "${BASE_URL}/vendor/xterm.js" | grep -q '200 OK'

say "checking HTTP tunnel"
curl -fsS -b "${WORK}/admin.cookies" \
  "${BASE_URL}/proxy/devices/smoke-device/v1/info?x=1" >"${WORK}/proxy.txt"
grep -q '^tunnel-ok:/v1/info?x=1$' "${WORK}/proxy.txt"

say "checking stream tunnel"
curl -fsS -b "${WORK}/admin.cookies" \
  "${BASE_URL}/stream/devices/smoke-device/stream" >"${WORK}/stream.txt"
diff -u <(printf 'one\ntwo\nthree\n') "${WORK}/stream.txt"

say "checking terminal tunnel"
(
  cd "${ROOT}/relay"
  TERM_WS_URL="ws://127.0.0.1:${PORT}/term/devices/smoke-device?cols=80&rows=24" \
  COOKIE_FILE="${WORK}/admin.cookies" \
  go run "${WORK}/term_client.go"
)

say "checking browser sessions"
curl -fsS -b "${WORK}/admin.cookies" "${BASE_URL}/api/admin/sessions" >"${WORK}/sessions.json"
grep -q '"current":true' "${WORK}/sessions.json"
curl -fsS -b "${WORK}/admin.cookies" \
  -X POST "${BASE_URL}/api/admin/sessions/revoke-others" >"${WORK}/revoke-others.json"
grep -q '"ok":true' "${WORK}/revoke-others.json"

say "checking device revoke"
curl -fsS -b "${WORK}/admin.cookies" \
  -X POST "${BASE_URL}/api/admin/devices/smoke-device/revoke" >/dev/null
curl -fsS -b "${WORK}/admin.cookies" "${BASE_URL}/api/admin/devices" >"${WORK}/devices-revoked.json"
grep -q '"status":"revoked"' "${WORK}/devices-revoked.json"

say "relay smoke passed"
