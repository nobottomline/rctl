# LAN Discovery, Access-Path Visibility, And Authenticated Local Pairing

Status: discovery/access-path code implemented; physical qualification and
authenticated pairing remain gated. Baseline inspected on
2026-09-10. It extends the implemented direct-IP flow in
[`MOBILE-LAN.md`](MOBILE-LAN.md), follows the work rules and gates of
[`MOBILE-PLAN.md`](MOBILE-PLAN.md), and uses the Devices screen rules in
[`MOBILE-DESIGN.md`](MOBILE-DESIGN.md). Increment C also depends on
[`CONTROLLER-AUTH.md`](CONTROLLER-AUTH.md).

This is the active plan. [MOBILE-LAN-REVIEW.md](MOBILE-LAN-REVIEW.md) records
the source-backed review and preserves both original drafts for comparison.
Increment C remains a design gate: its transport and bootstrap are not approved
for implementation until the security and migration questions below are resolved.

## Implementation Checkpoint (2026-09-10)

- B: immutable `RemoteSessionModel.accessPath`, persistent LAN/Relay label and
  endpoint in Session Controls. Existing visual components were reused; design
  polish and optional ICE-route/RTT diagnostics remain separate work.
- A: [discovery-v1](../protocol/discovery-v1.md), raw TXT fixtures/parser,
  daemon registration, bounded NWBrowser/DNS-SD resolution, foreground opt-in,
  explicit open/save/replace-address flows and manual fallback are implemented.
  Saved profiles remain v1. Capability probes are limited to four and do not
  run alongside discovery resolution.
- Rootful package installed with `scripts/deploy.sh`; real Mac NWBrowser ->
  resolver -> capabilities succeeded. Bonjour add/remove churn was observed
  despite a live daemon; sleep/network stability is not release-qualified.
- Rootless build/public package audit pass; device deployment and Bonjour on
  the rootless target remain unverified.
- C: [transport ADR and isolated TLS spike](../protocol/local-auth-v1.md).
  Host TLS 1.3 HTTPS with pinned Apple trust and wrong/missing-pin rejection
  passes. No runtime local-auth changes or new pairing endpoints were added.
- Remaining matrix: two devices, DHCP changes, physical controller permission
  denial/allow, guest networks, WAN-off and explicit Relay-only transitions.

## Outcome And Scope

An operator opens Devices, sees the iPads on the same network, taps one, and
connects without typing an address. Manual entry stays available, including on
networks that block multicast. An open session always shows whether it runs
over LAN or Relay. A paired device can later prove it is the operator's own
device, and the device accepts only paired, scoped controllers.

Three increments ship independently, in this order of risk:

| Increment | Outcome | Protocol impact |
|-----------|---------|-----------------|
| B. Access path | The session header always shows LAN or Relay with the endpoint and media route. | None. Can land first. |
| A. Discovery | Devices appear without an address; saved devices survive DHCP changes with explicit confirmation before pairing. | Additive discovery contract; allocate a protocol minor only when reviewed capabilities changes land. |
| C. Authenticated local pairing | Reviewed design for mutual authentication and scopes on the LAN. | Proposed `local.auth`; transport, endpoints and version remain behind the design gate. |

Discovery never depends on pairing and never describes a discovered device as
authenticated. Pairing is a trust-model change and gets its own review gate
before any runtime code lands.

## Current Implementation

Facts from the code that constrain the design:

- `daemon/main.mm` binds `0.0.0.0:8080` when `LocalAccessEnabled` is true and
  `127.0.0.1:8080` in Relay-only mode. `core/net/HttpStreamServer.mm` creates
  an IPv4-only listener (`socket(AF_INET, …)`); advertising an IPv6 address
  would advertise something the daemon cannot accept.
- Externally reachable entry points on port 8080: `/stream`, `/input`, `/key`,
  `/config`, `/orient`, `/audio_test`, `/ws/signal`, `/ws/term`,
  `/v1/pull_stream`, 55 `/v1/*` REST paths, and the static web client at `/`
  and `/vendor/*`. The virtual-microphone, camera-ingest, and audio listeners
  bind loopback only. Any authenticated-only mode must refresh and cover this
  inventory, including endpoints added by concurrent work, not a fixed path count.
- `DeviceID` is generated only when a relay entry exists
  (`core/net/RelayClient.mm`). A public LAN-only package has no stable
  identity today. The policy plist is written under an atomic lock shared with
  relay approval (`core/config/LocalAccess.mm`).
- Direct-LAN signaling in `core/net/Term.mm` sends an `open` envelope without
  scopes; the session receives every DataChannel.
- The daemon build pins Mbed TLS 3.6.6 (`third_party/webrtc/build-ios.sh`).
  It is a transport/crypto implementation candidate; verify required modules,
  entropy and each architecture rather than inferring a qualified new protocol
  from existing DTLS linkage. SpringBoard reports `UIDevice.name` through the device
  info query and already presents `UIWindow` overlays above alerts.
- The iOS app validates every local target through `LocalDeviceAddress`
  (private IPv4 or ULA literal), probes capabilities through an isolated
  `URLSession`, allows plaintext WebSocket only for the exact validated
  endpoint, and now probes saved addresses for reachability.
  `RemoteSessionModel.accessPath` preserves LAN/Relay independently of transient
  connection state. The controller identity is a P-256 key per relay;
  the current abstraction supports Secure Enclave and a software fallback.
- Bonjour registration lives in `core/net/LocalDiscovery.mm`; browsing,
  raw-record validation and DNS-only resolution live in `RctlRealtime`.

## Invariants

1. Relay-only devices do not advertise. Advertising or browsing failure never
   restarts the daemon, disables manual LAN access, or touches Relay.
2. Discovery never starts capture, opens WebRTC, sends input, or enrolls a
   controller. Connecting stays an explicit action and starts in View mode.
3. Service names, TXT records, and resolved addresses are untrusted hints.
   They grant nothing, and before Increment C they cannot silently replace a
   saved device's address.
4. TXT records carry no UDID, serial number, hostname, relay origin, token,
   signing-key fingerprint, persistent device ID, or controller identity.
5. No subnet scan, background discovery service, global ATS exception, TLS
   validation bypass, or implicit Relay-to-LAN or LAN-to-Relay fallback.
6. Access path (LAN or Relay signaling) and media route (direct, TURN, unknown)
   are distinct facts. Server-reflexive is a candidate type, not another access
   mode. A Relay session
   with a direct media path is still a Relay session.
7. Existing saved profiles, iOS 14 device runtime support, rootful and
   rootless packaging, and the controller's minimum iOS stay intact.
8. Contract changes land with documents and fixtures before dependent code.
   Discovery and the badge do not change relay auth; delegated local pairing
   would be an explicit additive relay contract requiring its own review.

## Increment B: Access Path Always Visible

Smallest change, no protocol impact, ships first.

- `RemoteSessionModel` publishes `accessPath` (`lan(LocalDeviceAddress)` or
  `relay(host:)`) derived once from the connection target and never mutated
  for the life of the session. Optional diagnostics add `mediaRoute`
  (`direct`, `relayed`, `unknown`) and round-trip time from the selected ICE
  pair and both candidate types. Sampling stops while suspended and clears
  stale values. Diagnostics must not delay shipping the access-mode indicator;
  ICE RTT is not measured end-to-end input latency.
- `RemoteSessionHeader` gets a chip beside the device name: `LAN` in the
  healthy tone or `Relay` in the signal tone, visible in every state including
  connecting, reconnecting, and failed. The subtitle becomes
  the session state. Full endpoints and route details belong in Session Controls
  instead of competing with device names in a compact header.
- `RemoteToolsSheet` adds a read-only `Connection` block: path, endpoint,
  route, RTT, protocol version, and whether the session is scoped. Once
  Increment C ships it also shows `Authenticated` or `Trusted network`.
- Accessibility: the chip reads "Connection path: local network" or
  "Connection path: relay"; color is never the only signal; the header stays
  usable in compact landscape and at the largest accessibility size.

Tests: header snapshots for both paths in every session state; a model test
that `accessPath` cannot change after start; a mapping test for each
candidate-pair type. Acceptance: the mode is always visible and never changes
implicitly.

## Increment A: Discovery

### Decisions

| Question | Decision | Alternatives and why not |
|----------|----------|--------------------------|
| Device advertisement | `DNSServiceRegister` from `<dns_sd.h>` inside `rctld` on a serial dispatch queue. | No embedded UDP 5353 fallback: diagnose system responder failures and retain manual IP; a second responder needs separate justification. |
| iOS discovery | `NWBrowser` with `.bonjourWithTXTRecord`, in `RctlRealtime` next to the LAN client. | `NetServiceBrowser` (deprecated); `DNSServiceBrowse` (no benefit on iOS 16). |
| Resolution | Bounded `DNSServiceResolve` plus `DNSServiceGetAddrInfo`, validating addresses before any application TCP connection; retain interface provenance and pin the chosen literal. | Connecting first with NWConnection can contact a prohibited destination before validation. Service URLs also bypass the current exact-target boundary. |
| Instance name | Generic `rctl` by default, with Bonjour collision handling and full endpoint disambiguation. Personal names require explicit opt-in. | Broadcasting a name increases passive exposure even when an API already returns it on request. |
| Stable identity in TXT | Defer until justified; service identity and explicit selection suffice for first discovery. If introduced, use a separate local hint, never relay DeviceID or an authorization key. | Unsigned IDs do not enable safe silent address replacement and add cross-network tracking. |
| Saved-address refresh | Before pairing: one-tap confirmation in the row. After pairing: automatic, because the verify handshake would fail against a hijacked address. | Silent refresh from an unsigned record (an mDNS spoofer could redirect input to itself). |
| IPv6 | Not advertised as connectable and not selected until the listener is dual-stack. IPv6-only results show `Unsupported network`. | Accepting ULA now (the daemon cannot accept it). |

### Service Contract

Service type `_rctl._tcp`, domain `local.`, SRV port equal to the bound HTTP
port, generic instance name bounded to 63 UTF-8 bytes. TXT record, one key per entry:

```text
txtvers=1
pv=<protocol major>.<protocol minor>
```

Model, daemon version, and features are deliberately absent: they come from
the capabilities preflight, which is also where the client verifies them.
Client limits: 400 encoded TXT bytes, at most 255 bytes per TXT entry,
64 visible results, 8 candidates per result, and bounded UTF-8 strings.
Define duplicate-key and malformed-field handling in fixtures.

No relay identity migration or capabilities identity object is required for
discovery. A future unsigned identity can detect accidental inconsistencies but
cannot authenticate or merge saved devices. Allocate protocol versions when
changes land, accounting for concurrent work rather than reserving minor 1.2.

Artifacts: `protocol/discovery-v1.md` (keys, limits, lifecycle), synthetic TXT
fixtures (valid, unknown key, oversized, malformed, duplicate name), and a
reviewed `discovery_txt_bytes` limit. Capabilities changes require a separate
consumer and compatibility fixtures before implementation.

### Privacy

Do not accept extra passive disclosure merely because active unauthenticated
queries already exist. TXT excludes tracking identifiers, names, fingerprints,
model and relay information by default. Bonjour SRV may still expose the system
hostname; a generic service name is data minimization, not network anonymity.

### Device Side

New `core/net/LocalDiscovery.{h,mm}`:

- `rctl_discovery_start(port, name, txt)` registers after `rctl_http_start`
  and the REST handler are installed; `rctl_discovery_stop()` deregisters on
  shutdown and on a policy transition. Relay-only mode never registers. A
  daemon crash drops the registration because the responder connection dies;
  restart must not accumulate entries.
- The generic name avoids depending on SpringBoard readiness. TXT may be
  updated through `DNSServiceUpdateRecord`; changing the service-instance name
  requires an appropriate registration lifecycle, not a TXT update.
- `kDNSServiceInterfaceIndexAny`; the responder chooses interfaces. Name
  conflicts, interface changes, and responder failures are logged with the
  `DNSServiceErrorType` and retried with bounded backoff (1 s doubling to
  60 s). None of them is fatal.
- `/v1/local_access` reports `"discovery": "starting" | "advertising" | "off" | "error"`
  for the relay admin device page and diagnostics.
  `advertising` means the responder accepted registration, not that every
  client currently sees it or can reach the device.
- Rootful and rootless linking of `libsystem_dnssd` is verified on device
  before the feature is enabled; a missing responder is a recoverable feature
  failure.

Host tests: TXT encoding limits and UTF-8 truncation. Device check: a Mac on
the same network sees the service with `dns-sd -B _rctl._tcp local.` and
resolves it with `dns-sd -L`.

### iOS Side

`RctlRealtime` gains transport-level types, no views:

- `LocalDeviceBrowser`: starts `NWBrowser` on demand, publishes bounded
  `[DiscoveredDevice]` (service identity, name, protocol version,
  endpoints per interface), groups results from several interfaces by service
  identity, debounces churn, and maps `.waiting` with `kDNSServiceErr_PolicyDenied`
  to a `permissionDenied` state. Cancels on dismissal, backgrounding, and
  network changes; stale callbacks from a superseded browse are ignored.
- `LocalDeviceResolver`: resolves at most four results concurrently, each
  bounded to 5 s, validates before opening any application connection, selects
  an RFC 1918 IPv4 literal, and reports
  `unsupportedAddressFamily` for IPv6-only results. Output is a
  `LocalDeviceAddress`, so every downstream check stays unchanged.
  Coordinate this budget with saved-address preflight probes; cap candidates
  per service at eight and do not spawn an unbounded probe on every TXT update.

The app:

- `Info.plist` adds `NSBonjourServices` with `_rctl._tcp` and updates
  `NSLocalNetworkUsageDescription` to describe discovery and direct
  connections.
- Permission flow: browsing is opt-in once. The Devices screen shows a
  `Find devices on this network` row; the first tap triggers the system Local
  Network prompt in context. After that opt-in, the `Nearby` group refreshes
  automatically whenever Devices is visible and the scene is active, and stops
  otherwise. Denied permission shows a callout with `Open Settings`; manual
  entry stays visible and states that it needs the same permission.
- Retain `LocalDeviceProfile` v1 UUID, address and custom name; transient browse
  results do not require a storage migration. Deduplicate saved entries only
  by exact endpoint or subsequently proven paired identity. If v2 becomes
  necessary, qualify migration, rollback and preservation of every v1 entry.
- `Nearby` rows show name, resolved address when available, and a
  `Discovered` chip; same-name devices are told apart by address. Tapping
  resolves if needed, runs the capabilities preflight, opens View mode, and
  offers `Save`. Advertisement alone shows `Discovered`; `Reachable` requires
  bounded preflight, coordinated with existing probes. A changed address shows
  `Use for saved device` with explicit selection/confirmation; do not infer
  the association from an unsigned name or ID. Once paired, prove the pinned
  identity before committing any new address. `Add by address` stays in the same group and is emphasized when
  browsing is denied or finds nothing within 6 s.

### Manual Fallback

Manual entry handles blocked multicast or responder failure only if unicast
is reachable. Client isolation can block both paths. Denied Local Network
permission affects both paths too. Ordinary Mac iproxy is not implemented by
this native iPhone flow: localhost is device-relative and the current address
policy rejects loopback. Discovery never merges manual entries by an unsigned
ID or edits their address without explicit confirmation.

### Failure States

| Condition | Behavior |
|-----------|----------|
| Local Network permission denied | Callout with Settings; manual entry stays; no retry loop. |
| No results within 6 s | Quiet hint "No devices found. Add by address." Browsing continues. |
| Result resolves to a public, loopback, multicast, or link-local address | `Unsupported network`; not connectable; nothing saved. |
| IPv6-only result | `Unsupported network` with the IPv6 reason. |
| Conflicting or changing resolution results | Discard stale attempt; a saved entry keeps its last confirmed address. |
| Advertised major differs | `Incompatible` with both majors; not connectable. |
| Relay-only device | Not advertised; a saved entry shows `Offline`. |
| Result flood or oversized TXT | Rejected before decoding; at most 64 rows. |

### Tests And Acceptance

- Package tests: TXT bounds, identity matching, resolver rejection of every
  unsupported family and range, v1 store migration, deduplication rules,
  interface grouping, cancellation and stale-callback handling, and browser
  state mapping with deterministic adapters. Existing loopback WebSocket tests
  do not prove Bonjour behavior; test real system registration separately.
- App tests: `Nearby` rendering with synthetic results, denied state,
  address-change confirmation, and no capture or signaling during browsing.
- Physical matrix: two iPads with the same name on port 8080; DHCP change
  while the app is open; Relay-only toggle tears down registration and closes
  access immediately, with remote-cache convergence measured separately;
  daemon restart re-registers once; rootful iOS 14 and rootless targets; iOS
  16, 17, and current on the controller; WAN disconnected; guest Wi-Fi and
  client isolation report unreachable unicast without promising manual entry
  can bypass it; VPN on
  and off without toggling it silently; browsing CPU, memory, and request
  rate profiled.

Acceptance: a fresh install on a home network connects without typing an
address; malicious TXT, names, endpoints, and floods cannot bypass the target
policy; a saved device survives an address change with one tap; no code path
grants access from a TXT value.

## Increment C: Authenticated Local Pairing

### Review Gate

This section is the protocol and threat-model proposal. Before runtime code
lands, it is reviewed as a whole for bootstrap UX, transport, policy
migration, browser impact, and recovery, and the decisions are recorded in
`protocol/local-auth-v1.md`. Bonjour stays untrusted discovery throughout.

### Threat Model

The network is hostile: an attacker sees, modifies, and injects LAN traffic,
runs a look-alike `_rctl._tcp` service with any name and TXT, and reaches port
8080. In today's open mode the attacker can use existing screen, terminal and
file APIs; we cannot assume the screen or root-owned files are private merely
because the attacker started without physical or root access. Pre-existing
device compromise cannot be repaired by a pairing ceremony.

Before displaying a secret QR or creating a device key, enter a protected setup
state through genuine local owner action or authenticated provisioning. Deny
new untrusted requests and close existing screen/camera streams, recordings,
downloads, terminals and remote input, including viewers without pairing rights.
Do not let remote input press Allow. Protect every capture path rather than
simply hiding an overlay from one renderer. If quiescence fails, pairing must
not begin. Persist this protection across crashes until explicit owner recovery;
never automatically restore the open listener after a failed ceremony.

Required properties:

1. A controller connects only to the device it paired with or fails loudly;
   a look-alike or a man-in-the-middle cannot obtain a session.
2. The device accepts sessions only from paired controllers, limited to the
   scopes granted at pairing, and can revoke any controller.
3. Pairing secrets never travel in clear and cannot be brute forced offline
   from captured traffic. Nobody becomes the owner by being first on the
   network.
4. Signaling cannot be altered in transit; the DTLS fingerprint in the SDP is
   bound to the authenticated channel.
5. Nothing weakens the relay path or the trusted-network path for
   installations that keep it, and no silent downgrade follows a key mismatch.

### Identities

- Device: create the long-term key only after protected setup is established.
  Select the algorithm through the reviewed transport; P-256 through existing
  Mbed TLS is a candidate. Use atomic root-owned storage and independent local
  identity, preserving it across supported upgrades. Mode 0600 does not protect
  the key from the root daemon's remote file API; enforce that boundary too.
  Root-terminal grants remain high-trust. The trusted fingerprint comes from
  pairing, never TXT. A wipe requires explicit re-pairing.
- Controller: a separate key per paired device, preferring Secure Enclave and
  documenting/testing the actual software fallback policy,
  through `KeychainControllerStore` with a `local:<device-id>` namespace, so
  revoking or losing one device affects nothing else. Relay refresh
  credentials are never sent to a LAN endpoint.

### Trust Bootstrap

Two bootstrap paths produce the same controller record on the device.

Path 1, owner-opened QR ceremony (works without a relay):

1. The owner enters protected setup; the daemon confirms that untrusted capture,
   input and file/terminal access are closed before generating pairing material.
2. Display a short-lived high-entropy QR through a trusted local UI, bound to
   the device key and one pairing window. Never expose its secret through an
   unauthenticated endpoint, log, saved screenshot or recording.
3. Scan on the controller, authenticate the encrypted channel against that trust
   anchor, and obtain deliberate approval of the exact controller and scopes.
4. Atomically consume the claim and persist identities/permissions. Define
   idempotent retry, cancellation, expiry and lost-response behavior.

The reviewed transport must specify the actual wire ceremony. The earlier
custom ECDH/HKDF/GCM recipe is retained only in the original draft, not approved
as an implementation spec. High-entropy secrets remove a low-entropy guessing
problem but do not prove the rest of a protocol correct.

One active owner ceremony may not be replaced by an unauthenticated request.
Return bounded busy/rate-limit responses; apply both per-source and global
limits, with deterministic tests for distributed cancellation/claim floods.
Limits and lockout must not turn remote abuse into permanent owner lockout.

Path 2, relay-delegated grant (no device interaction):

A relay administrator, already trusted to approve devices and create
controllers, grants an existing relay controller local access to a device.
The proposed additive relay grant must bind the device identity, a distinct
local controller key, exact scopes, expiry and a single-use identifier over the
existing authenticated channel. Device-key information reaches the controller
through authenticated TLS and a reviewed binding, not merely a signed request
to an endpoint (request signatures do not sign the response). Do not reuse a
relay refresh/admin credential or automatically import the relay signing key.
Persistent local access is a new delegated authority even if relay admins
already control the device; require explicit consent and define whether later
relay revocation also revokes the local grant. This requires its own contract
and tests, and cannot silently be considered an unchanged relay protocol.

Rejected: zero-interaction ownership without prior trust and first-claimant
wins. A short PIN would need a reviewed PAKE implementation, online limits and
its own platform qualification. It is not interchangeable with a high-entropy
out-of-band QR; neither makes the complete protocol automatically secure.

### Scopes

Reuse the scope vocabulary in `CONTROLLER-AUTH.md`, with a separately reviewed
`local.manage` grant for management. Default to `screen.view`; control, audio,
camera, microphone and files are deliberate choices, while terminal, update and
destructive actions remain advanced/high-trust. The owner approves the exact
set bound to both identities through the authenticated ceremony. Device-side
scopes come from stored grants, never client-supplied labels or TXT capabilities.

### Session Channel

Every protected operation needs authenticated encryption, including management,
files, commands and signaling. Authenticate before WebSocket upgrade or resource
allocation. Bind the WebRTC DTLS fingerprint to the authenticated signaling
channel. Passing server-derived scopes into the existing open envelope is
necessary but not sufficient: REST, stream downloads and terminals need the
same principal and revocation boundary. This is more than a codec layer.

Reuse signing helpers only with explicit local domain separation and binding
to device, controller, method/path/body and validity. Define authenticated clock
correction if time-based proofs remain. A bounded nonce cache must never evict
still-live replay protection to admit more work: reject excess work or use a
reviewed bounded session/challenge design. Test cache saturation, expiration,
restart, parallel requests and lost responses. Do not infer anti-replay safety
from a numeric cache limit alone.

### Transport Decision

Prefer a standard TLS-based prototype with pairing-anchored device trust and
maintained implementations. It protects both native REST and WebSocket traffic;
TLS alone does not solve authorization or browser certificate UX. Prototype
device key storage, IP changes, narrow trust evaluation, URLSession WSS, the iOS
14 daemon, rootless packaging and browser interoperability before final choice.
Do not accept arbitrary self-signed certificates or global TLS bypasses.

A maintained reviewed Noise/PAKE-based alternative may be considered if a
concrete platform constraint rules out TLS. It must cover every protected path
with bounded framing, cancellation, errors and lifecycle semantics. Do not ship
the bespoke sealed-channel draft just to avoid certificate integration: it
still introduces trust evaluation, protocol maintenance and a new RPC boundary.
Record prototype evidence and an explicit decision before allocating wire APIs.

### Policy Modes And Enforcement

The ADR evolves `LocalAccessEnabled` into explicit policy states while preserving
the boolean's meaning for existing installations. Protected setup is a required
phase; its exact persistence representation must be decided and crash-tested.

| Mode | HTTP bind | Unauthenticated surface | Native controllers |
|------|-----------|-------------------------|--------------------|
| `lan-open` (today's default) | all interfaces | everything, as today | unpaired trusted-network access; paired app access does not secure the device as a whole |
| protected setup | network surface restricted before secrets exist | explicitly reviewed bootstrap/health allowlist only | no untrusted streams, input, terminal or file sessions; persists safely on crash |
| `lan-paired` | protected authenticated listener(s), chosen by transport ADR | explicitly reviewed bootstrap/health allowlist only, no wildcard pairing-management exemption | only paired controllers with their scopes |
| `relay-only` | loopback | none from the network | none |

`lan-paired` is enforced at the request dispatcher, not per handler, against
the full inventory in Current Implementation: `/stream`, `/input`, `/key`,
`/config`, `/orient`, `/audio_test`, `/ws/signal`, `/ws/term`,
`/v1/pull_stream`, and every `/v1/*` path except the allow list return `403`
from the network. A host test asserts the inventory against the dispatcher
so a new endpoint cannot bypass the mode unnoticed. The principal must be checked
before upgrade/dispatch and existing sessions must be closed too. Loopback
reachability is not proof of relay-admin authority. Protected setup precedes
key creation; finishing setup requires an approved recovery-capable controller
and an explicit policy transition. Decide whether protected setup is a separate
persisted mode or an internal phase in the ADR. Reopening LAN through the local
SSH recovery command requires informed owner action and key-exposure warnings,
never an unauthenticated web reset. Until the
browser client has local authentication, `lan-paired` makes the web page
unusable from the network; the admin page says so before confirming.

On the controller, a device with a pinned identity always uses the authenticated
transport selected by the ADR. If the device answers without `local.auth` or with a
different identity, the app shows `Identity changed` with both fingerprints
and `Forget and pair again`; it never falls back to `/ws/signal` for a
pinned device.

### Revocation And Recovery

- Controller list and revoke operations over the authenticated channel require
  `local.manage`; revocation closes that controller's sessions within one
  second. Relay administrators reach the same operations through the
  authenticated relay tunnel, so a lost phone is revocable without the phone.
- The app lists paired devices with fingerprint, scopes, and `Forget`, which
  deletes the local pin/key. Forget is not remote revocation; offer those as
  distinct operations and explain offline revocation limitations.
- Device key replacement (wipe or explicit reset through the SSH CLI) requires
  re-pairing every controller; the daemon never rotates the key silently.
- Supported upgrades preserve key/records and policy atomically. An older daemon
  does not understand a new policy automatically: test compatibility or block
  unsupported downgrade before secure mode is enabled. No rollback may silently
  reopen an unauthenticated listener. Record a tested local recovery path.
- Audit: pairing creation, claim success or failure, grants, and revocations
  are logged with controller ids and source addresses, never secrets or keys.

### Contracts And Fixtures

- First deliver the ADR: threat/bootstrap, standard transport evidence, complete
  endpoint/principal inventory, atomic policy transitions, migration and recovery.
  Then specify `protocol/local-auth-v1.md` and matching schemas/limits for the
  chosen transport. A proposed relay grant requires an explicitly versioned
  additive contract, not reuse of credentials or assumptions about old relays.
- Fixtures under `protocol/fixtures/local-auth/`: golden pairing and verify
  exchanges with test keys, wrong-secret claim, replayed nonce, mismatched
  fingerprint, out-of-order sequence, oversized and malformed messages, and a
  future-minor extension under the selected transport.
- Allocate protocol minor and `local.auth` only after the contract is reviewed;
  do not couple this to discovery or presume minor 1.2 is still available.

### Tests And Acceptance

- Host tests: Mbed TLS vectors shared with the Swift tests, nonce cache
  bounds, rate limits and lockout, policy transitions under the plist lock,
  dispatcher inventory, and revocation closing sessions.
- Swift package tests: the same vectors, key namespacing, pinning,
  identity-change detection, sequence enforcement, and downgrade refusal.
- Security cases: man-in-the-middle during pairing, replayed claim, replayed
  upgrade, SDP tampering under the authenticated channel, look-alike service with a
  copied TXT record, scope escalation by editing the request, revoked
  controller mid-session, skew beyond the window, and a legacy endpoint
  probed in `lan-paired` mode. Include already-open viewers when pairing starts,
  synthetic key-file reads through root APIs, remote Allow input, distributed
  pairing replacement, replay-cache saturation, unauthenticated clock injection,
  process crashes and old-package downgrade. Never expose real keys in tests.
- Physical: pairing from an overlay scan in under 30 s; relay-delegated grant
  end to end; pairing survives daemon restart and package upgrade;
  `lan-paired` blocks an unpaired phone and the browser with the documented
  message; relay-side revocation; `Forget` then re-pair; identity change after
  a wipe.

Design acceptance: reviewed ADR, prototype evidence, endpoint/principal matrix,
accepted owner bootstrap, browser impact and tested recovery plan. Runtime code
requires a separately accepted implementation plan. Its security target is that
an attacker on the same network cannot claim ownership by racing,
spoofing Bonjour, replaying a grant, or using an overlooked legacy endpoint; a
device in `lan-paired` mode cannot be controlled by an unpaired client; the
relay path and `lan-open` behavior are unchanged for existing installations.

## Sequencing And Commits

```text
B. Access path      model + header + tools sheet                        (no protocol change)
A. Discovery        contract -> advertiser -> iOS browser/resolver -> Devices UI
C. Local pairing    source review -> transport/bootstrap prototype -> ADR + recovery/authorization matrix
                    -> separately accepted runtime implementation plan
```

Suggested commits, each verified on its own:

1. `feat(ios): persistently identify session access path`
2. `docs(protocol): define bounded LAN discovery records`
3. `feat(daemon): advertise available LAN control with Bonjour`
4. `feat(ios): discover and connect to local devices`
5. `test(lan): qualify discovery and lifecycle recovery`
6. `docs(protocol): specify authenticated local pairing` (review gate)

Unrelated concurrent input and web changes stay out of these commits. Plan
edits are not deployed.

## Open Decisions For The Owner

1. Ship `lan-paired` with pairing, or hold it until the browser client has
   local authentication so the mode does not disable the web page.
2. Choose the owner-approved protected-setup UX and recovery procedure. Merely
   displaying a QR in open mode is not safe; a tap is not physical proof while
   remote input can synthesize it.
3. Enable the relay-delegated grant in the first pairing release, or ship the
   QR path first and delegate later.

## References

- Apple, [TN3179 Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- Apple, [NWBrowser](https://developer.apple.com/documentation/network/nwbrowser),
  [DNS Service Discovery C API](https://developer.apple.com/documentation/dnssd),
  and the [DNS-SD programming guide](https://developer.apple.com/library/archive/documentation/Networking/Conceptual/dns_discovery_api/Introduction/Introduction.html)
- RFC 6762 (Multicast DNS), RFC 6763 (DNS-Based Service Discovery, TXT rules)
- RFC 5869 (HKDF), RFC 9700 section 4.14.2 (sender-constrained tokens, as
  used by the relay path)
- [TLS 1.3](https://www.rfc-editor.org/rfc/rfc8446.html): standard transport
  candidate; pairing trust, authorization and browser UX remain separate.
- HomeKit Accessory Protocol pair-verify, prior art for the
  ephemeral-then-sign session handshake
