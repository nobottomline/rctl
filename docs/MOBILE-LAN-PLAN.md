# LAN Discovery And Pairing Plan

Status: planned, not implemented. Baseline inspected on 2026-09-10.
This document extends [the implemented direct-LAN flow](MOBILE-LAN.md).

## Outcome And Scope

An operator opens Devices, chooses Find Local Devices, selects an available
device, and connects without typing its address. Manual IP entry remains
available, including on networks that block multicast. An open session always
identifies its configured access mode as LAN or Relay.

Deliver discovery and mode visibility first. Design authenticated local pairing
as a separate protocol milestone; do not make discovery depend on that migration
or describe discovered devices as authenticated.

## Current Implementation

- `daemon/main.mm` starts `rctl_http_start`, installs handlers, and observes the
  persisted LAN/Relay-only policy. Advertising belongs to this process, not to
  SpringBoard, the foreground-app payload, or the relay.
- `core/net/HttpStreamServer.mm` currently creates an IPv4 listener. Advertising
  an IPv6 address is not evidence that this listener can accept it.
- `LocalDeviceAddress` accepts private IP literals; `LocalDeviceClient` bounds
  capabilities requests and isolates LAN from relay credentials.
- `LocalDevicesModel` persists saved addresses and now probes their reachability.
  Discovery must cooperate with those probes rather than duplicate requests.
- `RctlRealtimeSession` shares the WebRTC implementation between LAN and Relay.
- `RemoteControlView` already knows the access mode, but only uses it in the
  transient connection label. `RemoteSessionHeader` is the persistent UI target.
- No Bonjour registration or browser implementation exists in these components.

## Invariants

1. Relay-only devices do not advertise LAN access. Bonjour failure must not
   disable manual LAN access, restart the daemon, or disrupt Relay.
2. Discovery never starts capture, opens WebRTC, sends input, or enrolls a
   controller. Connection remains an explicit operator action and starts in View.
3. Device names, TXT records, service instance names, and announced identifiers
   are untrusted hints. They confer no authorization and cannot silently replace
   an existing saved device or establish that two endpoints are the same device.
4. No UDID, serial number, relay identifier, hostname from private configuration,
   token, public-key fingerprint, or controller identity appears in TXT records.
5. No network-wide IP scan, background discovery service, global ATS exception,
   TLS-validation bypass, or implicit Relay-to-LAN fallback is introduced.
6. Preserve saved profiles, iOS 14 device runtime support, rootful/rootless
   packaging, and the controller's existing minimum iOS version.

## Phase 1: Discovery Contract And Advertiser

Proposed service type: `_rctl._tcp` in the local Bonjour domain. Confirm the
service-type naming/registration requirements before public distribution.

- Document the v1 record in `protocol/bonjour-v1.md`, with synthetic fixtures.
  Advertise the actual HTTP port through SRV, not a hard-coded TXT URL.
- Keep TXT minimal: discovery format version and device protocol major/minor.
  Omit unknown optional fields safely; reject malformed required fields.
  Full capabilities are fetched only when needed through the existing API.
- Default to a generic instance name such as `rctl`; let Bonjour resolve name
  collisions. Do not reuse the system hostname or a personal device name by
  default. An operator-supplied discovery name can be a later explicit option.
- Initial client limit: 1 KiB aggregate TXT data, bounded strings and at most
  64 visible service results. Reject oversized values before decoding.
- Implement a small daemon-owned wrapper, proposed
  `core/net/BonjourAdvertiser.{h,mm}`, using the system DNS-SD API
  (`DNSServiceRegister`) and a serial dispatch queue. Do not add another HTTP
  server, Avahi process, or external discovery dependency.
- Start registration only after the listener and relevant request handlers are
  ready and LAN is enabled. Stop/deallocate on shutdown or policy transition.
  Process death releases the registration; restart must not accumulate entries.
- Handle name conflicts, interface changes, and mDNS responder failure. Use
  bounded backoff for transient registration errors and rate-limited diagnostics.
- Check device SDK/linking requirements on rootful and rootless. Missing or
  failing discovery support is a recoverable feature failure, not a daemon crash.

Acceptance: two same-port devices advertise distinct service instances; the
public package needs no configuration; Relay-only mode advertises neither a
loopback endpoint nor a stale usable LAN service. No media starts on discovery.

## Phase 2: iOS Browser And Address Resolution

- Add a transport-level `LocalDiscoveryBrowser` beside the existing LAN client
  in `RctlRealtime`, using Apple's `NWBrowser`. No new SPM package is necessary
  solely for this feature. Expose bounded results/state, not SwiftUI views.
- Browse only `_rctl._tcp` after explicit Find Local Devices intent. Declare
  `NSBonjourServices` and update `NSLocalNetworkUsageDescription` to describe
  both discovery and direct connections. Do not request broader entitlements
  unless the selected APIs and physical-device tests establish a need.
- Tie browsing to the discovery screen's lifetime. Cancel browser, resolution,
  and pending probes on dismissal/backgrounding; invalidate stale callbacks
  after network changes or a newer operation. Keep results transient.
- Resolve the selected service using supported system DNS-SD resolution, retaining
  its domain/interface context. Do not weaken `LocalDeviceAddress` to accept an
  arbitrary hostname or URL from TXT. Use at most four concurrent resolutions
  or capability probes and bound each operation's duration.
- Validate resolved candidates and pin each HTTP/WS attempt to a selected
  literal address. Reject public, loopback, multicast, unspecified, and currently
  unsupported link-local destinations. Do not re-resolve an unchecked hostname
  inside URLSession or follow a redirect to another target.
- First release selects RFC1918 IPv4 candidates because the daemon listener is
  IPv4-only. Surface a specific unsupported-address result for IPv6-only devices.
  Dual-stack listener support and scoped link-local IPv6 are separate increments.
- Reuse the bounded capabilities preflight before saving/connecting. Report
  unsupported protocol separately from vanished service, resolution failure,
  and permission denial. An empty browse result does not prove permission denial.

Acceptance: a valid result reaches the existing LAN WebRTC path; malicious TXT,
hostnames, endpoints, and floods do not bypass the local target policy. Manual
IP entry works when multicast discovery is unavailable. If Local Network
permission is denied, manual entry remains available but cannot bypass that
permission; guide the operator to Settings before retrying either path.

## Phase 3: Device List And Persistent Mode Indicator

- Add Find Local Devices alongside Add Local Device. The discovery sheet shows
  named results with address/port when resolved, refresh/stop controls, and clear
  searching, empty, denied, incompatible, and failed states.
- Selection shows the resolved target and connects only after explicit approval.
  Saved entries retain their existing UUID and custom name. Reuse exact-endpoint
  deduplication; never merge by display name alone.
- Handle a result arriving through multiple interfaces without duplicate rows:
  group transient candidates by service identity, preserving per-interface
  addresses for resolution. Identical names in different scopes remain distinct.
- Do not overwrite a saved address after DHCP changes based only on an unsigned
  advertisement. Initially require explicit confirmation of an address change;
  cryptographic device identity can enable safer matching in the pairing phase.
- Feed a typed access-mode value into `RemoteSessionHeader`. Always show LAN or
  Relay while connecting, viewing, controlling, reconnecting, or failed.
  Ensure VoiceOver, Dynamic Type, contrast, and compact landscape layouts work.
- Keep the distinction between access mode and media route: Relay signaling can
  carry direct peer-to-peer media. Do not label that session LAN merely because
  its ICE candidate pair is direct. Authenticated is a separate future status.

Acceptance: users connect without typing an IP; manual entry/edit/remove still
work; two same-name devices are distinguishable; the session's mode is always
visible and never changes implicitly.

## Phase 4: Authenticated Local Pairing Design

Deliver a reviewed ADR and protocol/threat-model proposal, not an improvised
authentication patch. Scope the design across daemon, protocol, mobile, browser,
package upgrades, and recovery. Bonjour remains untrusted discovery.

### Trust Bootstrap

- A clean public package contains no shared secret. Generate a device key on
  the device, persist it across upgrades with restricted permissions using the
  established runtime paths, and keep it independent of relay identity.
- Generate a separate controller identity and keep private credentials in
  Keychain. An endpoint changing address must prove the same trusted device key.
- Default proposal: explicit, short-lived pairing window plus a one-time
  high-entropy QR/out-of-band secret bound to the device key. Require deliberate
  owner authorization; Bonjour data cannot provide this trust anchor. Display
  the secret through a trusted local UI or provision it through an authenticated
  channel, never an unauthenticated LAN endpoint anyone can read.
- For the desired no-device-setup experience, evaluate delegation through an
  already authenticated relay/controller trust relationship or secure personal
  provisioning. Bind a narrowly scoped grant to device and controller public
  keys; never reuse or send relay refresh credentials to the LAN endpoint.
- Without prior trust, personal provisioning, or an out-of-band confirmation,
  secure zero-interaction ownership assignment is not possible. Do not silently
  assign the first claimant on the network. A short numeric code is not a bearer
  credential; choosing one would require a reviewed PAKE implementation and
  online attempt limits, not a custom challenge/hash scheme.

### Transport And Enforcement

- Prefer a standard authenticated encrypted transport, with TLS and a device
  identity anchored by pairing, using maintained system/library implementations.
  Prototype compatibility with URLSession WebSockets, iOS 14 daemon runtime,
  changing IPs, and browser clients before selecting the final transport.
- Do not treat signed HTTP requests alone as confidentiality or device identity
  protection. Protect signaling, response bodies, files and commands, including
  the WebRTC negotiation's identity/fingerprint binding. Never accept every
  self-signed certificate or install an application-wide TLS trust bypass.
- Specify one-time consumption, expiry, anti-replay, per-controller permissions,
  revocation, bounded per-source and global attempt limits, maximum active pairing
  attempts, safe error messages, and secret-free auditing.
- In authenticated-only mode, enforce policy across every externally reachable
  legacy HTTP, WebSocket and DataChannel control/media/file/terminal entry point.
  An authenticated app beside an unrestricted legacy endpoint is not a secured
  device. Separate genuinely required health/bootstrap endpoints explicitly.
- Model authenticated LAN separately from today's trusted unauthenticated LAN
  and Relay-only policy. Preserve existing behavior until the owner deliberately
  migrates; no silent downgrade after a key mismatch or rejected authorization.
- Define lost-phone revocation, multiple controllers, device-key replacement,
  package upgrades, rollback, and owner recovery without reliance on WAN access.

Acceptance: an attacker on the same network cannot claim ownership by racing,
spoofing Bonjour, replaying a grant, or using an overlooked legacy endpoint.
The ADR must decide bootstrap UX, encrypted transport, browser compatibility,
policy migration and recovery before authentication implementation begins.

## Verification And Delivery

- Protocol fixtures: versions, unknown fields, oversized/malformed TXT, duplicate
  names, conflicting records, public addresses, and changing resolution results.
- Deterministic lifecycle tests: canceled browser/resolver/probe, stale callback,
  disappearing result, permission denial, responder restart and network switch.
- Regression: saved manual profiles, reachability probes, Relay pairing/reset,
  credential isolation, View/Control gating, and failed-discovery fallback.
- Physical matrix: iPhone controller plus rootful iOS 14 and rootless iOS 15
  targets, two devices on port 8080, all supported controller iOS versions,
  WAN disconnected, guest Wi-Fi/client isolation, VPN on/off, app backgrounding,
  daemon restart, and LAN/Relay-only transitions. Do not toggle VPN silently.
- Verify no capture starts during browsing and profile discovery CPU, memory,
  battery and request rate. Advertising/browsing failures must not affect an
  already connected session.
- Run focused native/protocol tests, mobile package/app tests, both package
  build/audit lanes and browser/relay regressions if their contracts change.
  Device packages require on-device verification, not just compilation.

Suggested commits, each independently verified:

1. `docs(protocol): define bounded LAN discovery records`
2. `feat(daemon): advertise available LAN control with Bonjour`
3. `feat(ios): discover and connect to local devices`
4. `feat(ios): persistently identify session access mode`
5. `test(lan): qualify discovery and lifecycle recovery`
6. `docs(security): specify authenticated local pairing`

Phase 3's mode indicator can ship earlier without waiting for discovery. Phases
1-3 do not change authentication. Phase 4 authorizes design only; its runtime
implementation requires a separately accepted plan. Keep unrelated concurrent
input/web changes out of these commits; do not publish or deploy a plan-only edit.

## References

- [NWBrowser](https://developer.apple.com/documentation/network/nwbrowser)
- [Apple local-network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [DNS-SD programming guide](https://developer.apple.com/library/archive/documentation/Networking/Conceptual/dns_discovery_api/Introduction/Introduction.html)
