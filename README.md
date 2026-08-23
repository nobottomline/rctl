# rctl

Self-hosted remote control for jailbroken iOS 14 devices.

[![Latest release](https://img.shields.io/github/v/release/nobottomline/rctl)](https://github.com/nobottomline/rctl/releases/latest)
[![CI](https://github.com/nobottomline/rctl/actions/workflows/ci.yml/badge.svg)](https://github.com/nobottomline/rctl/actions/workflows/ci.yml)
[![iOS 14](https://img.shields.io/badge/iOS-14.0%2B-111111)](docs/PORTABILITY.md)

rctl streams the device screen and audio to a browser, injects real touch and
keyboard input, exposes a root terminal, transfers files, browses Photos, and
controls camera and system actions. It works directly on a trusted local network
or through an authenticated relay hosted on your own VPS.

> [!WARNING]
> rctl provides root-level control of the device. The local port is
> unauthenticated and must never be forwarded to the public internet. Use the
> TLS relay for internet access and read the [security model](docs/SECURITY.md)
> before deployment.

## Features

- Low-latency H.264 screen streaming over WebRTC
- Touch, keyboard, hardware buttons, clipboard, and app launching
- Device playback audio, room microphone, intercom, and virtual microphone
- Root PTY terminal and bounded file transfer
- Photos and video library with preview, download, copy, and protected deletion
- Front and rear camera streaming, still capture, and device-side recording
- Multi-device, multi-relay enrollment with revocable browser sessions
- Transactional signed updates with watchdog verification and rollback
- No setup UI, account, or secret entry on the iPad

Physical-device qualification and known limitations are tracked in
[docs/QUALIFICATION.md](docs/QUALIFICATION.md).

## Quick Start

Choose one deployment profile.

### Self-hosted relay

Use this profile for access outside the local network. You need a fresh
Debian/Ubuntu VPS, a domain or subdomain pointing to it, and ports `80` and `443`
available. SSH to the VPS and run:

```sh
curl --proto '=https' --tlsv1.2 -fsSL \
  https://github.com/nobottomline/rctl/releases/latest/download/install.sh | \
  sudo sh
```

The verified Go wizard checks the host and DNS, installs the pinned relay stack,
obtains TLS, and verifies HTTPS and persistence. It does not require cloning the
repository or installing a compiler.

1. Open the HTTPS admin URL printed by the wizard.
2. Sign in with the generated admin secret.
3. Select **Pair device** and download the private `.deb`.
4. Install that package on the jailbroken device and approve the pending device.
5. Open the device from the admin page.

The personalized package contains a one-time enrollment credential. Keep it
private and delete it after installation. The device stores its long-lived relay
identity automatically; there is nothing to configure on iOS.

For pinned releases, non-interactive installs, upgrades, backup/restore, bare-IP
constraints, and recovery, see the [setup guide](docs/SETUP.md).

### Local network only

Download `rctl_<version>_iphoneos-arm.deb` from the
[latest release](https://github.com/nobottomline/rctl/releases/latest), install it
with the device package manager, and open:

```text
http://<device-ip>:8080/
```

The public package contains no relay address or credentials. It remains a simple
LAN-only artifact and can later be replaced by a personalized package without
changing the control client.

## Network Access Modes

Relay-enabled devices default to **LAN + Relay**, preserving direct local access
even when the VPS is unavailable. An administrator can switch an approved online
device to **Relay only** from its action menu in the relay admin page.

In Relay-only mode, `rctld` binds port `8080` to `127.0.0.1`. Relay tunneling keeps
working, but direct Wi-Fi and USB browser connections are rejected. The daemon
will not enable this mode until it has at least one approved, persistent relay
identity. See [security and recovery](docs/SECURITY.md#local-network-policy).

## How It Works

```text
Browser  <-- WebRTC / authenticated HTTPS -->  Relay (optional)
   |                                                |
   +--------------- HTTP / WebRTC -----------------+
                              |
                           rctld
                       /       |       \
             SpringBoard   foreground app   mediaserverd
             screen/input   camera/vmic     playback audio
```

The root daemon owns the network and relay transports. Small injected components
remain within the process that owns each private iOS capability. Local control
and relay control use the same device APIs, so feature behavior does not diverge
between deployment profiles. The full component and trust-boundary design is in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Build From Source

Device builds require macOS, Theos, an iOS 14.5 SDK, and the pinned WebRTC native
dependencies. The control and admin clients require Node.js; the relay requires
Go.

```sh
make deps
make test
make package FINALPACKAGE=0
```

Use `scripts/deploy.sh` for a physical test device. Do not use `make package
install`: rctl uses a clean, verified install flow to avoid stale arm64e signing
state and to preserve relay identity safely.

Relevant checks:

```sh
(cd web && npm ci && npm run build)
(cd relay && go test ./...)
(cd relay/web-admin && npm ci && npm run lint && npm run build)
make release-check
```

See [docs/PORTABILITY.md](docs/PORTABILITY.md) for supported architectures and
[docs/QUALIFICATION.md](docs/QUALIFICATION.md) before publishing an artifact.

## Repository

| Path | Ownership |
| --- | --- |
| `daemon/`, `core/` | Root API server, transports, security, and shared native code |
| `springboard/` | Screen capture and input injection |
| `app/`, `audio/` | Camera, microphone, and playback-audio hooks |
| `web/` | Canonical device control client |
| `relay/` | Go relay, VPS wizard, and separate admin client |
| `layout/` | Public package payload and lifecycle scripts |
| `docs/` | Architecture, protocols, operations, and qualification |

Start with [docs/README.md](docs/README.md). Protocol changes must preserve iOS
14 support, local operation, relay credential isolation, and compatibility by
protocol major.

## Security

- Never expose device port `8080` to the internet.
- Never publish a personalized `.deb`, relay database, signing key, or config.
- Use trusted HTTPS/WSS and a dedicated high-entropy admin secret.
- Keep the jailbreak and VPS patched, and revoke sessions or devices no longer
  in use.
- Report suspected vulnerabilities privately to the repository owner; do not
  include credentials, device identifiers, or production data in an issue.

Detailed guarantees, destructive-operation protections, and recovery procedures
are documented in [docs/SECURITY.md](docs/SECURITY.md).
