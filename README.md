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

As of 2026-09-19, **GitHub latest is `0.4.4`**, with separate rootful and
ordinary Dopamine rootless packages. **The APT feed remains `0.3.2` (rootful)**.
The maintainer authorized latest publication before the full qualification
matrix was complete; [release notes](https://github.com/nobottomline/rctl/releases/tag/v0.4.4)
identify the outstanding checks. Back up and retain independent recovery access
before upgrading. Native controller work in current source is not a released app.

Physical testing covers an iPad Air 3 (`iPad11,3`) on iPadOS 14.4 with rootful
unc0ver/Substitute and an iPad Pro on iPadOS 15.5 with Dopamine/ElleKit. Both
passed the relay-admin device update from `0.4.3` to the exact `0.4.4` candidate,
with relay identity preserved and subsequent LAN/relay control checks. This is
not blanket support for iOS 15/16, every device, or RootHide.

| Profile | Status | Installation |
| --- | --- | --- |
| Local network, rootful iOS 14 | Public | [APT `0.3.2`](https://nobottomline.github.io/rctl-repo/) or [GitHub `0.4.4`](https://github.com/nobottomline/rctl/releases/tag/v0.4.4) |
| Self-hosted internet relay | Available; wizard features depend on release | Private package produced by the VPS wizard |
| Rootless Dopamine, tested on iPadOS 15.5 | Public GitHub package; qualification limits apply | [Rootless guide](docs/ROOTLESS.md); not yet in the APT feed |

See the [device release checkpoint](docs/ROOTLESS-RELEASE.md) and
[VPS qualification record](docs/SETUP-QUALIFICATION.md) for exact versions,
passed checks, and remaining limits. [QUALIFICATION.md](docs/QUALIFICATION.md)
defines the publication gates; a successful test is not a published release.

## Features

- Low-latency H.264 screen streaming over WebRTC
- Touch, text and Game keyboard input, captured mouse, hardware buttons,
  clipboard, and app launching
- Device playback audio, room microphone, intercom, and virtual microphone
- Root PTY terminal and bounded file transfer
- Photos and video library with preview, download, copy, and protected deletion
- Front and rear camera streaming, still capture, and device-side recording
- Multi-device, multi-relay enrollment with revocable browser sessions
- Transactional signed updates with watchdog verification and rollback
- No setup UI, account, or secret entry on the controlled device

## Install

Choose one deployment profile. The public repository and personalized relay
packages intentionally remain separate.

### Local network

Open the **[rctl package repository](https://nobottomline.github.io/rctl-repo/)**
on the jailbroken device, choose Cydia, Installer, Sileo, or Zebra, and install
`rctl`.
For the newer `0.4.4` package, use the
[latest GitHub release](https://github.com/nobottomline/rctl/releases/latest).
Choose `iphoneos-arm` for rootful or `iphoneos-arm64` for ordinary Dopamine
rootless; these are separate packages, not interchangeable files. Follow the
[rootless installation guide](docs/ROOTLESS.md) for dependencies and installation.

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

The `0.4.4` wizard implements searchable local domain hints, manual
domain entry, and confirmed Docker Engine/Compose installation on a clean host.
The `latest` command above selects the published release, never a draft.
Older installers may require Docker Engine and Compose v2 beforehand.
Domain hints cannot enumerate every domain pointing to a VPS;
choose a domain you control. See [setup inputs](docs/SETUP.md#bootstrap-contract)
for DNS, public IPv4, and optional certificate-contact email behavior.

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

The `0.4.4` release includes an **Updates** section backed by a restricted host
service: automatic release checks, confirmed relay installation, and optional
scheduled automatic server updates. Device DEB updates require their own
confirmation and preserve relay pairings; upgrading the server does not update
devices automatically. Older installations need one verified bootstrap upgrade
to enable the host service. See [update behavior and recovery](docs/SETUP.md#admin-managed-server-updates).

## Network Modes

Relay-enabled devices default to **LAN + Relay**, preserving direct local access
when the VPS is unavailable. An administrator can switch an approved online
device to **Relay only** from its action menu in the relay admin page.

In Relay-only mode, `rctld` binds port `8080` to `127.0.0.1`. Relay tunneling
continues to work, while direct LAN connections are rejected.
The daemon refuses this mode until it has an approved persistent relay identity.

**Relay login and revocation do not protect the independent LAN port.** Use
Relay-only mode before joining shared or untrusted Wi-Fi. First approve the
device, verify relay control, and establish an independent recovery path such
as SSH. The policy is device-wide, survives package upgrades, and does not
silently re-enable LAN if the relay goes offline. Installation does not change
an existing explicit policy. See [security and recovery](docs/SECURITY.md#local-network-policy).

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
