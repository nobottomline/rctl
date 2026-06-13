# Internet Relay Plan

The public release `.deb` is LAN-only. It must not contain a relay domain, VPS IP,
admin secret, enrollment token, or any maintainer-owned infrastructure value.

Internet access is opt-in through a per-user package generated after the normal
build. The generated package embeds only that user's relay URL and enrollment
token, so it must never be published as a GitHub release artifact.

## User Flow

1. User deploys their own relay on a domain with HTTPS/WSS.

   ```sh
   cd relay
   cp .env.example .env
   $EDITOR .env
   docker compose up -d --build
   ```

   Put Caddy, Nginx, or another TLS reverse proxy in front of
   `127.0.0.1:8080`. The repository includes production-oriented examples:
   `relay/Caddyfile.example`, `relay/nginx.conf.example`, and
   `relay/nginx_proxy_params.example`.

2. User opens the admin panel and creates an enrollment token:

   ```text
   https://rctl.example.com/admin
   ```

   The admin panel supports login, device listing, enrollment creation, approve,
   and revoke. The same operations are also available over HTTP API:

   ```sh
   curl -sS -c /tmp/rctl.cookies \
     -H 'Content-Type: application/json' \
     -d '{"secret":"your-admin-secret"}' \
     https://rctl.example.com/api/admin/login

   curl -sS -b /tmp/rctl.cookies \
     -X POST https://rctl.example.com/api/admin/enrollments
   ```

3. User creates a local device package config:

   ```sh
   cp relay.env.example relay.env
   $EDITOR relay.env
   ```

   Example:

   ```text
   RELAY_URL=wss://rctl.example.com/device
   ENROLL_TOKEN=token-returned-by-the-relay
   DEVICE_NAME=iPad Air 3
   ```

4. User builds a private relay-enabled package:

   ```sh
   make package-relay
   ```

5. User installs the generated package from `personalized/`.
6. The device appears in the relay admin panel as pending.
7. User approves the device from the browser. After approval, the relay issues a
   long-lived device secret and the enrollment token is no longer accepted.
8. User opens the relay-hosted control page:

   ```text
   https://rctl.example.com/control/devices/{device_id}
   ```

   The relay serves the same browser client as local LAN mode, but injects
   authenticated proxy and stream paths for that device.

The iPad does not need any on-device setup after installing the personalized
package. The package installs the relay config file and the existing `postinst`
reloads `rctld`, so the daemon reads the config on startup.

`scripts/personalize_deb.sh` is the lower-level command behind
`make package-relay`. It can still be used directly by automation or CI.

Docker is the recommended self-hosted install path because it standardizes
environment variables, the SQLite volume, restarts, and port binding. The
relay is still a normal Go binary; advanced users can run it directly under
systemd.

## VPS Deployment

Recommended baseline:

```sh
cd relay
cp .env.example .env
openssl rand -base64 48
openssl rand -base64 48
$EDITOR .env
docker compose up -d --build
```

Set these values in `.env`:

```text
RCTL_RELAY_PUBLIC_URL=https://rctl.example.com
RCTL_RELAY_ADMIN_SECRET=<first openssl value>
RCTL_RELAY_SESSION_SECRET=<second openssl value>
RCTL_RELAY_TRUST_PROXY_HEADERS=1
RCTL_RELAY_ALLOW_INSECURE=0
```

`compose.yaml` publishes the relay only on `127.0.0.1:8080`. Keep it that way
on a public VPS. The public internet should reach only the TLS reverse proxy on
ports 80 and 443.

### Caddy

Use Caddy when possible. It gets and renews certificates automatically.

```sh
sudo cp relay/Caddyfile.example /etc/caddy/Caddyfile
sudo $EDITOR /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

The Caddy example overwrites forwarding headers before traffic reaches the
relay, so `RCTL_RELAY_TRUST_PROXY_HEADERS=1` is safe with that topology.

### Nginx

Nginx is also supported, but certificate automation is separate.

```sh
sudo cp relay/nginx_proxy_params.example /etc/nginx/rctl_proxy_params
sudo cp relay/nginx.conf.example /etc/nginx/sites-available/rctl
sudo ln -s /etc/nginx/sites-available/rctl /etc/nginx/sites-enabled/rctl
sudo nginx -t
sudo systemctl reload nginx
```

The Nginx example overwrites `X-Forwarded-For` and `X-Real-IP` with
`$remote_addr`; do not replace that with `$proxy_add_x_forwarded_for`.

### Smoke Checks

After DNS and TLS are active:

```sh
curl -fsS https://rctl.example.com/healthz
curl -I https://rctl.example.com/admin
```

Then open:

```text
https://rctl.example.com/admin
```

Create an enrollment token, build a private package with `make package-relay`,
install it, approve the pending device, then use the `Open` button in the admin
panel.

### Production Checklist

- DNS `A`/`AAAA` record points to the VPS.
- Only ports 80 and 443 are public; relay port 8080 is bound to `127.0.0.1`.
- `RCTL_RELAY_PUBLIC_URL` is the final `https://` domain.
- `RCTL_RELAY_ALLOW_INSECURE=0`.
- `RCTL_RELAY_TRUST_PROXY_HEADERS=1` only when using a proxy config that
  overwrites `X-Forwarded-For` and `X-Real-IP`.
- `RCTL_RELAY_ADMIN_SECRET` and `RCTL_RELAY_SESSION_SECRET` are long random
  values and are not reused anywhere else.
- The public GitHub release `.deb` is built with plain `make package`, not
  `make package-relay`.
- The private relay-enabled `.deb` from `personalized/` is never uploaded to a
  public release.

## Single Domain Routing

One domain is enough, even for many devices:

```text
https://rctl.example.com/healthz
https://rctl.example.com/api/admin/login
https://rctl.example.com/api/admin/devices
https://rctl.example.com/api/admin/sessions
https://rctl.example.com/control/devices/{device_id}
https://rctl.example.com/proxy/devices/{device_id}/v1/info
https://rctl.example.com/stream/devices/{device_id}/stream
wss://rctl.example.com/device
wss://rctl.example.com/client/devices/{device_id}
```

The relay stores devices in SQLite and keeps online WebSocket connections in
memory by `device_id`. Hundreds of mostly idle devices are realistic on a small
VPS. Video traffic is the real limit: active viewers consume bandwidth and CPU
because the relay forwards encrypted streams between browser and device.

Subdomains are not required. They can be added later for hosted multi-tenant
deployments, but path-based routing is simpler and better for self-hosted users.

## HTTP Tunnel

The relay exposes an authenticated request/response tunnel:

```text
/proxy/devices/{device_id}/{local_path...}
```

Example:

```sh
curl -b cookies.txt \
  https://rctl.example.com/proxy/devices/ipad-air-3/v1/info
```

The relay sends a bounded `http_request` message to the online device over the
device WebSocket. `rctld` performs the request against its local LAN server at
`http://127.0.0.1:8080/{local_path...}` and returns `http_response`. This is for
normal REST/control requests first. Long-lived streaming endpoints such as
`/stream` need a separate streaming tunnel so one large response cannot block the
control plane.

## Stream Tunnel

Long-lived streams use a separate authenticated endpoint:

```text
/stream/devices/{device_id}/{local_path...}
```

Example:

```sh
curl -b cookies.txt \
  https://rctl.example.com/stream/devices/ipad-air-3/stream
```

The relay sends `stream_open` over the device WebSocket. `rctld` opens the local
LAN stream at `http://127.0.0.1:8080/{local_path...}` using a streaming
`NSURLSessionDataDelegate` and forwards `stream_start`, `stream_chunk`, and
`stream_end` messages back to the relay. If the browser disconnects, the relay
sends `stream_cancel` so the device closes the local stream.

The local LAN/USB server remains independent. Installing a relay-enabled package
does not disable or replace `http://<ipad-ip>:8080` or `http://localhost:8080`
over USB forwarding.

## Relay-Hosted Web Client

The relay can serve the existing web client directly:

```text
/control/devices/{device_id}
```

This route requires an authenticated admin browser session and an approved
device. It reads `web/index.html`, injects:

```text
RCTL_PROXY_BASE=/proxy/devices/{device_id}
RCTL_STREAM_BASE=/stream/devices/{device_id}
```

and serves static client dependencies from `web/vendor/`. The normal released
LAN package still opens the same `web/index.html` without injected globals, so
all local paths keep going directly to `rctld`.

In Docker, `web/` is copied into the image and `RCTL_RELAY_WEB_DIR=/app/web`.
When running the Go binary directly, set `RCTL_RELAY_WEB_DIR` to the repository
`web/` directory if the default `../web` does not match your working directory.

## Browser Sessions

Admin browser sessions are stored server-side in SQLite and authenticated with
`HttpOnly` cookies. The admin panel shows active sessions, marks the current
browser, and can revoke another session or every other session. The API also
supports revoking all sessions, which clears the current browser cookie too:

```text
GET  /api/admin/sessions
POST /api/admin/sessions/{session_id}/revoke
POST /api/admin/sessions/revoke-others
POST /api/admin/sessions/revoke-all
```

## Users Without a Domain

Production remote control should use a domain with trusted TLS. Browser
WebSockets, cookies, and user trust are all cleaner with `https://` and `wss://`.

For users who only have a VPS IP:

- recommended: buy/use any cheap domain and point an `A` record to the VPS;
- acceptable advanced option: use a tunnel provider that gives a trusted HTTPS
  hostname;
- local/dev only: set `RCTL_RELAY_ALLOW_INSECURE=1` and use `http://IP:PORT`,
  but do not expose that mode to the public internet.

The project should not document plain public HTTP as a safe setup.

## Implementation Choice

The relay is written in Go. Rust would also be valid, but Go is the better fit
for this self-hosted relay right now: simple HTTP/WebSocket server code, one
portable binary, fast iteration, easy Docker builds, and a lower maintenance
burden for open source users. The latency-sensitive media path can still evolve
to WebRTC/datachannel later; the relay remains useful for auth, signaling, and
fallback forwarding.

## Device Config

Personalized packages place this file on the device:

```text
/var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist
```

Keys:

```text
Enabled      bool    true to enable internet relay mode
RelayURL     string  wss:// URL for the device WebSocket endpoint
EnrollToken  string  per-user enrollment token, minimum 32 chars
DeviceID     string  generated on-device stable relay id
DeviceSecret string  issued by relay after browser approval
DeviceName   string  optional display name
```

`DeviceID` must be URL-safe: ASCII letters, digits, `.`, `_`, or `-`, up to 80
characters. Empty IDs are generated by the device/relay.

`rctld` reads this config at startup and opens the device WebSocket. It uses
`DeviceSecret` after approval, otherwise the short-lived `EnrollToken`. When the
relay sends an `approved` message, `rctld` stores `DeviceSecret` locally and
removes `EnrollToken` from the plist.

## Security Rules

- Use a domain and TLS. The device endpoint must be `wss://`.
- Never put secrets in committed files, release packages, screenshots, or logs.
- Audit logs should record security events, device/session ids, and remote IPs,
  but never admin secrets, enrollment tokens, device secrets, or cookies.
- Do not use URL query parameters for browser secrets.
- Enrollment tokens should be short-lived and single-use.
- Browser auth should use an admin login and `HttpOnly Secure SameSite` cookies.
- The relay must support revoking browser sessions and devices.
- Rate-limit login, enrollment, and device claim attempts.
- Leave `RCTL_RELAY_TRUST_PROXY_HEADERS=0` unless the relay is reachable only
  through a reverse proxy that sanitizes `X-Forwarded-For` and `X-Real-IP`.
- Current app-level rate limits:
  - `RCTL_RELAY_LOGIN_MAX` / `RCTL_RELAY_LOGIN_WINDOW`
  - `RCTL_RELAY_ADMIN_MAX` / `RCTL_RELAY_ADMIN_WINDOW`
  - `RCTL_RELAY_DEVICE_MAX` / `RCTL_RELAY_DEVICE_WINDOW`
- Keep reverse-proxy or firewall rate limits as an outer layer too.

## Git Hygiene

Ignored local files include:

```text
.env
.env.*
relay.env
*.secret
*.token
personalized/
relay-config.plist
```

Before publishing a release, verify that the `.deb` was produced by plain
`make package`, not `make package-relay` or `scripts/personalize_deb.sh`.
