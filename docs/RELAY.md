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
   `127.0.0.1:8080`.

   Docker is the recommended self-hosted install path because it standardizes
   environment variables, the SQLite volume, restarts, and port binding. The
   relay is still a normal Go binary; advanced users can run it directly under
   systemd.

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

The iPad does not need any on-device setup after installing the personalized
package. The package installs the relay config file and the existing `postinst`
reloads `rctld`, so the daemon reads the config on startup.

`scripts/personalize_deb.sh` is the lower-level command behind
`make package-relay`. It can still be used directly by automation or CI.

## Single Domain Routing

One domain is enough, even for many devices:

```text
https://rctl.example.com/healthz
https://rctl.example.com/api/admin/login
https://rctl.example.com/api/admin/devices
wss://rctl.example.com/device
wss://rctl.example.com/client/devices/{device_id}
```

The relay stores devices in SQLite and keeps online WebSocket connections in
memory by `device_id`. Hundreds of mostly idle devices are realistic on a small
VPS. Video traffic is the real limit: active viewers consume bandwidth and CPU
because the relay forwards encrypted streams between browser and device.

Subdomains are not required. They can be added later for hosted multi-tenant
deployments, but path-based routing is simpler and better for self-hosted users.

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

`rctld` reads this config at startup and opens the device WebSocket. It uses
`DeviceSecret` after approval, otherwise the short-lived `EnrollToken`. When the
relay sends an `approved` message, `rctld` stores `DeviceSecret` locally and
removes `EnrollToken` from the plist.

## Security Rules

- Use a domain and TLS. The device endpoint must be `wss://`.
- Never put secrets in committed files, release packages, screenshots, or logs.
- Do not use URL query parameters for browser secrets.
- Enrollment tokens should be short-lived and single-use.
- Browser auth should use an admin login and `HttpOnly Secure SameSite` cookies.
- The relay must support revoking browser sessions and devices.
- Rate-limit login, enrollment, and device claim attempts.
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
