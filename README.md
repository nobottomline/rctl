# rctl

Self-hosted remote control for jailbroken iOS devices.

[![Latest release](https://img.shields.io/github/v/release/nobottomline/rctl)](https://github.com/nobottomline/rctl/releases/latest)
[![CI](https://github.com/nobottomline/rctl/actions/workflows/ci.yml/badge.svg)](https://github.com/nobottomline/rctl/actions/workflows/ci.yml)
[![APT repository](https://img.shields.io/badge/APT-package%20repository-168568)](https://nobottomline.github.io/rctl-repo/)
[![License](https://img.shields.io/badge/license-Apache--2.0-3b4553)](LICENSE)
[![Qualified platform](https://img.shields.io/badge/qualified-iPadOS%2014.4%20rootful-111111)](docs/PORTABILITY.md)

rctl streams the device screen, camera, and audio to a browser; injects touch
and keyboard input; exposes a root terminal; and provides controlled access to
files, Photos, applications, and system actions. It works directly over a
trusted local network or through an authenticated relay hosted on your own VPS.

**[Install the public package](https://nobottomline.github.io/rctl-repo/)** ·
[Read the documentation](docs/README.md) ·
[Review security](docs/SECURITY.md) ·
[See changes](CHANGELOG.md)

> [!WARNING]
> rctl provides root-level control of the device. The local port is
> unauthenticated and must never be forwarded to the public internet. Use the
> TLS relay for internet access and read the [security model](docs/SECURITY.md)
> before deployment.

## Project Status

The current public package is physically qualified on an iPad Air 3
(`iPad11,3`) running iPadOS 14.4 with rootful unc0ver and Substitute. The code
retains an iOS 14 deployment target and `arm64`/`arm64e` support, but newer iOS
versions, rootless jailbreaks, and other injectors are not advertised as
supported until their physical-device qualification matrix passes.

| Profile | Status | Installation |
| --- | --- | --- |
| Local network, rootful iOS 14 | Public | [Cydia/Installer/Sileo/Zebra repository](https://nobottomline.github.io/rctl-repo/) |
| Self-hosted internet relay | Available | Private package produced by the VPS wizard |
| Rootless Dopamine, iOS 15+ | Experimental, not device-qualified | [Manual test build](docs/ROOTLESS.md); not in the APT feed |

Release readiness and known limitations are recorded in
[docs/QUALIFICATION.md](docs/QUALIFICATION.md).

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

## Install

Choose one deployment profile. The public repository and personalized relay
packages intentionally remain separate.

### Local network

Open the **[rctl package repository](https://nobottomline.github.io/rctl-repo/)**
on the jailbroken device, choose Cydia, Installer, Sileo, or Zebra, and install
`rctl`.
The same verified public `.deb` is attached to the
[latest GitHub release](https://github.com/nobottomline/rctl/releases/latest).

After installation, open:

```text
http://<device-ip>:8080/
```

The public package contains no relay address or credential. Repository signing,
release synchronization, and isolation from personalized packages are described
in [docs/APT-REPOSITORY.md](docs/APT-REPOSITORY.md).

### Self-hosted relay

Use this profile for access outside the local network. You need a fresh
Debian/Ubuntu VPS, a domain or subdomain pointing to it, and ports `80` and `443`
available. SSH to the VPS and run:

```sh
(
  set -e
  installer="$(mktemp)"
  trap 'rm -f "$installer"' 0
  curl --proto '=https' --tlsv1.2 -fsSL \
    https://github.com/nobottomline/rctl/releases/latest/download/install.sh -o "$installer"
  if [ "$(id -u)" -eq 0 ]; then sh "$installer"; else sudo sh "$installer"; fi
)
```

The verified Go wizard checks the host and DNS, installs the digest-pinned relay
stack, obtains TLS, and verifies HTTPS and persistence. It does not require a
repository clone or compiler.

The upcoming setup wizard offers searchable local domain hints, manual domain
entry, and confirmed Docker Engine/Compose installation on a clean host. Older
published installers require Docker Engine and Compose v2 beforehand. The
`latest` URL selects the published release, never a draft. Domain hints are not
a complete list of domains pointing to the VPS; choose a domain you control.

1. Open the HTTPS admin URL printed by the wizard.
2. Sign in with the generated admin secret.
3. Select **Pair device** and download the private `.deb`.
4. Install the package on the jailbroken device and approve the pending device.
5. Open the device from the admin page.

The personalized package contains a one-time enrollment credential. Keep it
private and delete it after installation. The device stores its long-lived relay
identity automatically; there is nothing to configure on iOS. For pinned
releases, non-interactive installation, upgrades, backup, and recovery, read
[docs/SETUP.md](docs/SETUP.md).

## Network Modes

Relay-enabled devices default to **LAN + Relay**, preserving direct local access
when the VPS is unavailable. An administrator can switch an approved online
device to **Relay only** from its action menu in the relay admin page.

In Relay-only mode, `rctld` binds port `8080` to `127.0.0.1`. Relay tunneling
continues to work, while direct Wi-Fi and USB browser connections are rejected.
The daemon refuses this mode until it has an approved persistent relay identity.
See [security and recovery](docs/SECURITY.md#local-network-policy).

## Architecture

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

The root daemon owns network and relay transports. Small injected components
remain in the process that owns each private iOS capability. Local and relay
control use the same device APIs, preventing feature drift between deployment
profiles. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for component and
trust boundaries.

## Build From Source

Start with the [development guide](docs/DEVELOPMENT.md) for prerequisites,
component-specific checks, and rootful/rootless package builds. Web and relay
work do not require a jailbroken device; native device builds require macOS,
Theos, the appropriate iOS SDK, and pinned native dependencies.

Installation is separate from building. Use the documented deployment path,
never `make package install`, and complete the
[qualification gates](docs/QUALIFICATION.md) before publishing artifacts.

## Repository Layout

| Path | Ownership |
| --- | --- |
| `daemon/`, `core/` | Root API server, transports, security, and shared native code |
| `springboard/` | Screen capture and input injection |
| `app/`, `audio/` | Camera, microphone, and playback-audio hooks |
| `web/` | Canonical device control client |
| `relay/` | Go relay, VPS wizard, and separate admin client |
| `mobile/` | Independent native controller applications |
| `protocol/` | Versioned wire contracts and generated constants |
| `layout/` | Public package payload and lifecycle scripts |
| `docs/` | Architecture, protocols, operations, and qualification |

Start with [docs/README.md](docs/README.md). Protocol changes must preserve iOS
14 support, local operation, relay credential isolation, and compatibility by
protocol major.

## Security

- Never expose device port `8080` to the internet.
- Never publish a personalized `.deb`, relay database, signing key, or config.
- Use trusted HTTPS/WSS and a dedicated high-entropy admin secret.
- Keep the jailbreak and VPS patched, and revoke unused sessions and devices.
- Report vulnerabilities through
  [GitHub private vulnerability reporting](https://github.com/nobottomline/rctl/security/advisories/new).

See [SECURITY.md](SECURITY.md) for supported versions and disclosure guidance,
and [docs/SECURITY.md](docs/SECURITY.md) for the product security model.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Bug reports
must be sanitized of device identifiers, relay URLs, tokens, terminal output,
and personal media.

## License

Licensed under the [Apache License 2.0](LICENSE). Third-party files retain their
respective licenses and notices.
