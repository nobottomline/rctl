# Tailscale Integration

Status: qualification in progress. No embedded Tailscale agent is shipped in
the public DEB. LAN and self-hosted relay remain the supported connection
modes; this document separates proposed integration from measured evidence.

## User Choices

Tailscale is an additional private network path, not a replacement for relay.
The controlling computer/phone must join the user's tailnet too. A browser
alone on an unrelated network cannot reach a private Tailscale address.
Internet connectivity is still required at both ends. No purchased domain or
self-hosted VPS is required for the ordinary Tailscale service, but that
service still coordinates connections and can carry encrypted fallback
traffic through DERP. Direct connectivity is not guaranteed.

| Choice | Intended setup | Main boundary |
| --- | --- | --- |
| Official app | Install Tailscale on the controlled device and controller, sign into one tailnet, connect, then use the device address | Official iOS client currently requires iOS 15+; existing VPN coexistence and inbound rctl reachability require testing |
| Embedded agent | Authorize from another computer; enroll an optional agent without installing the Tailscale app on the controlled device | Experimental; iOS 15 is the initial target, not a rootless-only product restriction |
| Subnet router | An always-on supported home computer/router joins Tailscale and advertises an approved route to the device | No device Tailscale app; works independently of the device's Go/iOS compatibility, but needs another machine |

For the official-app first test, preserve the existing rctl installation and
VPN. Coordinate any VPN switch before attempting it. Limit tailnet grants to
the intended controllers: current trusted-LAN rctl access is not independently
authenticated merely because the destination is a Tailscale address. Reaching
`http://<tailnet-address>:8080/` is a connectivity test, not qualification of all
features. Encrypted VPN traffic does not turn HTTP into a browser secure
context; microphone/clipboard features still require HTTPS.

For subnet routing, prefer a device-specific `/32` route over exposing the
entire household subnet. Approve routes and restrict access deliberately.
HTTPS and secure-context features need a separately qualified gateway path;
subnet routing alone does not provide them.

## Embedded Design

Use a separate userspace `tsnet` helper, not Go inside SpringBoard, the
foreground app or mediaserverd. This avoids a system VPN profile/TUN interface
for that helper. Whether it works alongside a particular existing VPN must
still be tested; userspace networking is not a guarantee against VPN policy.

The intended setup is a desktop/local wizard:

1. Choose official app, embedded access or subnet routing. Keep relay optional
   and independent; do not require a VPS just to prepare Tailscale access.
2. For embedded access, authorize the user's tailnet, select permitted
   controller identities and prepare a one-time enrollment. No shared project
   account, reusable global key or pre-generated node identity in packages.
3. Install a private bootstrap package once. Generate and persist the node
   identity on that device. Consume/remove bootstrap material after successful
   enrollment. Public upgrades must preserve identity and include the enabled
   helper, rather than orphaning a personalized package's executable.
4. Show the private HTTPS address and connection state. Subsequent controllers
   join the tailnet and are explicitly authorized. Revocation must terminate
   existing sessions, not only reject future page loads.

The HTTPS gateway must enforce identity, same-origin/CSRF rules and narrow
rctl access before forwarding any route. Tailscale network grants and a UI
toggle are not substitutes for gateway authorization. Do not use Funnel or
publish the root device API on the internet. Persisted node private keys stay
outside package payloads and repository state with owner-only permissions.

The current `Relay only` policy requires an approved relay. Do not silently
reuse it for Tailscale: a future access-policy change needs explicit persisted
semantics and a tested recovery path. LAN remains unchanged by default.

## WebRTC Boundary

`tsnet` provides userspace TCP/UDP sockets. The existing libdatachannel/libjuice
stack uses native sockets and cannot discover the embedded node as a normal
network interface. An HTTPS reverse proxy therefore does not establish video,
camera or DataChannel connectivity.

The first bridge candidate is standard TURN: a tailnet-facing packet listener
with native UDP allocations on the device. Pion supports the needed
`net.PacketConn` boundary, avoiding a proprietary datagram protocol or an
immediate libjuice fork. This is a candidate, not an adopted production route.
Validate native ICE acceptance and actual browser connectivity before wiring
it into the package or UI.

A production bridge must bind credentials to an authenticated session, limit
allocations and bandwidth, and restrict **both IP and port** to that session's
approved rctl peer. TURN's ordinary IP-only permission is insufficient to
protect other local services. Screen and camera have separate PeerConnections;
both need signaling and cleanup. Lost viewers, revoked identities and expired
leases must close allocations and release input/media without keeping the
device awake. Prefer an upstream-supported alternative if this boundary fails
qualification; do not claim WebSocket fallback as WebRTC support.

## Compatibility and Gates

Tailscale v1.102.4 requires Go 1.26.6. Go's current compatibility table lists
Go 1.26 as the last line supporting iOS 15 and Go 1.24.13 for iOS 14. Thus a
current tsnet dependency is **not** a supported iOS 14 build simply because
the deployment flag is lowered. Do not ship a stale networking/security stack
just to claim compatibility. Rootful iOS 14 embedded access requires a separate
maintained solution or remains unsupported; subnet routing is the initial
no-app alternative. Rootful/rootless package layout is distinct from iOS API
and Go runtime compatibility.

Qualification order:

1. Official app on iOS 15: reachability over a different network, HTTPS
   capability limits, native WebRTC versus fallback, existing VPN interaction.
2. Embedded runtime, enrollment, HTTPS identity checks and revocation on iOS 15.
3. Native WebRTC bridge: screen, camera, audio, Talk, terminal, input and files;
   direct and DERP paths, loss/reconnect, bounded queues and idle power.
4. Lifecycle: restart, reboot/re-jailbreak, expired/revoked node, public package
   upgrade/rollback, multiple controllers, concurrent relay, LAN recovery.
5. Subnet-router path with iOS 14; separately decide whether a maintained
   embedded iOS 14 implementation is feasible.

## Evidence: 2026-09-19

The isolated [tailnet probe](../tools/tailnet-probe/README.md) builds with
Go 1.26.6 and Tailscale v1.102.4 for iOS/arm64, minimum iOS 15.0. Local race
tests cover diagnostic authorization boundaries, private files and a loopback
Pion TURN packet round trip with invalid-credential/peer rejection.

Physical-device execution is **not qualified**: the ad-hoc signed probe exits
137 before printing `--check` output on the iOS 15.5 Dopamine test device. An
independent minimal C executable fails identically, including when using the
iOS 15.6 SDK rather than Xcode's current SDK. This does not establish a tsnet
runtime incompatibility; device executable trust/launch must be diagnosed
first. No Tailscale node has been registered by the probe, no device API was
exposed, and installed rctl, VPN and relay configuration were left unchanged.

## Upstream References

- [Official iOS client](https://tailscale.com/docs/install/ios)
- [tsnet server API](https://tailscale.com/docs/reference/tsnet-server-api)
- [Auth keys and their lifecycle](https://tailscale.com/docs/features/access-control/auth-keys)
- [HTTPS certificates](https://tailscale.com/docs/how-to/set-up-https-certificates)
- [Connection types](https://tailscale.com/docs/reference/connection-types)
- [Subnet routers](https://tailscale.com/docs/features/subnet-routers)
- [Go Darwin compatibility](https://go.dev/wiki/Darwin)
- [Pinned Tailscale module](https://github.com/tailscale/tailscale/blob/v1.102.4/go.mod)
- [Pion TURN](https://github.com/pion/turn/tree/v5.1.2)
