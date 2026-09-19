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

### Official App and Remote Control

The official clients joined the same tailnet on a macOS controller and an
iOS 15.5 Dopamine device running the existing rctl package. Tailscale discovery,
TSMP and ICMP succeeded. Initial ordinary IPv4 TCP requests timed out while
LAN HTTP returned 200. Inspection showed a competing macOS route for
`100.64.0.0/10` through the ordinary Wi-Fi gateway. Tailscale's own dialer and
an explicitly Tailscale-source-bound HTTP request both reached rctl and
returned 200. The installed rctl server did not need a transport patch for
that failure. Concurrent VPN connections were not disabled during diagnosis.

A temporary loopback-only diagnostic proxy bound its upstream TCP connections
to the controller's Tailscale address. The browser used that proxy for HTTP
and WebSocket signaling. To avoid falsely qualifying a same-LAN video path,
the diagnostic signal filter removed non-Tailscale ICE candidates from both
trickle messages and SDP, and rejected the `/stream` HTTP fallback. The proxy
was test infrastructure, not a shipped connection mode or user workaround.

Observed through the browser UI:

- WebRTC video rendered at approximately 60 fps / 1024 x 1366 with initial
  same-Wi-Fi RTT around 7-12 ms and zero displayed freezes/drops at that point.
- After moving the controlled device to a phone hotspot, the same browser tab
  recovered video. Tailscale reported a direct public endpoint rather than the
  household LAN endpoint. Typical observed RTT was around 49-80 ms, with spikes
  above 400 ms. This establishes a different-network path, not DERP acceptance.
- A Control Center command visibly changed the remote screen, and a remote
  tap dismissed it. The terminal connected and printed a synthetic marker.
- The hot-spot session accumulated dropped frames and brief freezes, including
  network handover. Do not characterize this as loss-free performance or full
  feature qualification just because the displayed frame rate recovered.
- A short Balanced-profile comparison showed approximately 30 fps, an
  unchanged dropped-frame counter and one additional brief freeze. The source
  scene and mobile network were not controlled, so this is not a benchmark or
  proof that the lower bitrate solves every freeze. Smooth was restored.

The loopback browser origin is treated as a secure context by browsers. It
does **not** qualify Talk/clipboard over the device's ordinary HTTP Tailscale
URL. Camera, audio/Talk, bulk files, prolonged idle/power behavior, DERP,
revocation and unattended recovery remain untested in this diagnostic route.

### Direct Browser Follow-Up

A node attribute targeted only at the macOS controller's existing Tailscale
IPv4 address, `one-cgnat?v=false`, was accepted and saved by the Tailscale
policy editor. Existing access grants and SSH rules were preserved. The
controller then installed a peer-specific `/32` route through the Tailscale
interface instead of selecting the competing Wi-Fi `/10` route. An ordinary
HTTP request, with neither source binding nor a proxy, returned 200. Both
Tailscale and the concurrent VPN remained connected.

With the controlled device still on a phone hotspot, the browser opened its
Tailscale HTTP address directly. WebRTC screen video rendered around 60 fps
at 1024 x 1366. A Control Center command, a tap to dismiss it, and a terminal
command with a synthetic marker succeeded. Reloading the page restored video
without intervention on the device. No diagnostic proxy, candidate filter or
rctl relay was used for this check.

During this session, `tailscale ping` reported DERP fallback. Browser RTT was
commonly around 140-190 ms, with an observed spike above 500 ms. Dropped-frame
and freeze counters increased. The direct browser test did not constrain ICE
candidates or verify the selected pair's addresses: a DERP ping alone does
not prove that WebRTC media used DERP rather than another available ICE path.
This is not forced-DERP media qualification or a loss-free performance claim.
No transport or quality defaults were changed to conceal the network behavior.

This resolves the observed controller route conflict, not every VPN conflict.
The direct HTTP origin still lacks browser secure-context capabilities;
Talk/clipboard, HTTPS setup, camera/audio, bulk files, power behavior and
revocation require separate qualification. The embedded agent is unaffected
and remains experimental.

### Route Troubleshooting

Do not disable an existing VPN, flush routes, or rewrite the tailnet policy as
an automatic response to a failed browser connection. A successful
`tailscale ping` does not establish that ordinary application TCP takes the
same route. On macOS, compare the route and an explicitly bound request:

```sh
route -n get "$DEVICE_TAILSCALE_IPV4"
curl --noproxy '*' --connect-timeout 5 --max-time 10 \
  --interface "$CONTROLLER_TAILSCALE_IPV4" \
  "http://$DEVICE_TAILSCALE_IPV4:8080/" -o /dev/null -w '%{http_code}\n'
```

If only the bound request succeeds, inspect the conflicting VPN's routes and
Tailscale routing policy. Change only the specific conflicting configuration
after confirming its purpose; preserve the existing internet/recovery path.
Tailscale's per-node route-granularity capability (`one-cgnat?v=false`) prefers
peer `/32` routes. The direct-browser follow-up above verified this setting
with a single controller IPv4 target. It is not a blanket instruction to
change every node or replace the access policy. Preserve unrelated policy
entries, preview the diff, and verify the actual route and ordinary HTTP
request afterward. Route updates can briefly disrupt active connections.
Removing only the added node-attribute entry restores the previous automatic
route selection; do not change grants, device tags or other VPN configuration
as part of this workaround.

IPv6 SSH connectivity also succeeded, but rctl's current HTTP listener binds
IPv4 only. Enabling an unrestricted `[::]` listener would expand exposure on
other interfaces and is not an acceptable silent workaround. Any IPv6 product
support must carry the local-access policy and loopback protections with it.

### Embedded Prototype

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

Follow-up: SSH transfer checksums matched, and the exact diagnostic binary's
code-directory hash was registered through Dopamine's `jbctl`. The hash was
present in the trust cache (its output uses uppercase hexadecimal), but the
binary still exited 137, including from a fresh file. Minimal C comparisons
without chained fixups and with Apple's ad-hoc signer also failed to launch.
These results rule out a Go-only failure and do not justify disabling code
validation or changing the jailbreak. Device-side launch remains unresolved;
no respring or package replacement was performed for these probes. Temporary
device executables were removed afterward. The diagnostic hash remains in
the current jailbreak trust cache; clearing unrelated entries is not part of
test cleanup.

The isolated tool now has an explicit experimental `--rctl` HTTPS gateway
mode. Its default remains diagnostic-only. The gateway checks the selected
Tailscale identity and the device's LAN-enabled policy, enforces same-origin
requests and a fixed loopback upstream, and bounds concurrent work. Streaming
responses and WebSockets are canceled when periodic identity/policy checks
fail or the gateway stops. Tests use disposable TLS endpoints and synthetic
traffic, not live identities, media or credentials. See the tool's README for
the route exclusions and lifecycle contract.

This is source-level gateway groundwork, not on-device HTTPS acceptance.
Certificate issuance/renewal, actual control-plane revocation propagation,
browser Talk/clipboard and the embedded ICE bridge remain open. The official
app route still uses the existing HTTP listener; neither it nor a new HTTPS
listener was installed as a side effect of these tests.

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
- [Concurrent VPN limitations](https://tailscale.com/docs/reference/faq/other-vpns)
- [CGNAT conflict diagnosis](https://tailscale.com/docs/reference/troubleshooting/network-configuration/cgnat-conflicts)
- [Pinned per-node routing capability definitions](https://github.com/tailscale/tailscale/blob/v1.102.4/tailcfg/tailcfg.go)
