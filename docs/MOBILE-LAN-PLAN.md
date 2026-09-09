# LAN Discovery, Access-Path Visibility, And Authenticated Local Pairing

Status: implementation plan, nothing shipped. Baseline inspected on
2026-09-10. It extends the implemented direct-IP flow in
[`MOBILE-LAN.md`](MOBILE-LAN.md), follows the work rules and gates of
[`MOBILE-PLAN.md`](MOBILE-PLAN.md), and uses the Devices screen rules in
[`MOBILE-DESIGN.md`](MOBILE-DESIGN.md). Increment C also depends on
[`CONTROLLER-AUTH.md`](CONTROLLER-AUTH.md).

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
| A. Discovery | Devices appear without an address; saved devices survive DHCP changes. | Additive: `_rctl._tcp` record, optional `device` object in capabilities (minor 1.2). |
| C. Authenticated local pairing | Mutual authentication and scopes on the LAN. | New `local.auth` feature, `/v1/local/*` endpoints, sealed signaling channel (minor 1.2). |

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
  bind loopback only. Any authenticated-only mode must cover exactly this list.
- `DeviceID` is generated only when a relay entry exists
  (`core/net/RelayClient.mm`). A public LAN-only package has no stable
  identity today. The policy plist is written under an atomic lock shared with
  relay approval (`core/config/LocalAccess.mm`).
- Direct-LAN signaling in `core/net/Term.mm` sends an `open` envelope without
  scopes; the session receives every DataChannel.
- The daemon links Mbed TLS 3.6.6 (`third_party/webrtc/build-ios.sh`), so
  P-256 ECDH/ECDSA, HKDF, and AES-GCM exist on the device without a new
  dependency. SpringBoard already reports `UIDevice.name` through the device
  info query and already presents `UIWindow` overlays above alerts.
- The iOS app validates every local target through `LocalDeviceAddress`
  (private IPv4 or ULA literal), probes capabilities through an isolated
  `URLSession`, allows plaintext WebSocket only for the exact validated
  endpoint, and now probes saved addresses for reachability.
  `RemoteControlView` knows whether a session is local but shows it only in the
  transient connection label. The controller identity is a Secure Enclave
  P-256 key per relay.
- No Bonjour or mDNS code exists in the repository.

## Invariants

1. Relay-only devices do not advertise. Advertising or browsing failure never
   restarts the daemon, disables manual LAN access, or touches Relay.
2. Discovery never starts capture, opens WebRTC, sends input, or enrolls a
   controller. Connecting stays an explicit action and starts in View mode.
3. Service names, TXT records, and resolved addresses are untrusted hints.
   They grant nothing, and before Increment C they cannot silently replace a
   saved device's address.
4. TXT records carry no UDID, serial number, hostname, relay origin, token,
   or controller identity. The one stable value they carry, the device
   identity, is a random value with no relation to hardware or relay secrets.
5. No subnet scan, background discovery service, global ATS exception, TLS
   validation bypass, or implicit Relay-to-LAN or LAN-to-Relay fallback.
6. Access path (LAN or Relay signaling) and media route (direct, reflexive,
   relayed ICE pair) are distinct facts and are shown as such. A Relay session
   with a direct media path is still a Relay session.
7. Existing saved profiles, iOS 14 device runtime support, rootful and
   rootless packaging, and the controller's minimum iOS stay intact.
8. Every increment lands with its protocol document and fixtures before code
   that depends on them, and none changes the relay contract.

## Increment B: Access Path Always Visible

Smallest change, no protocol impact, ships first.

- `RemoteSessionModel` publishes `accessPath` (`lan(LocalDeviceAddress)` or
  `relay(host:)`) derived once from the connection target and never mutated
  for the life of the session, plus `mediaRoute` (`direct`, `reflexive`,
  `relayed`, `unknown`) and round-trip time sampled every 3 s from the
  selected ICE candidate pair in the PeerConnection statistics report.
  Sampling stops while suspended.
- `RemoteSessionHeader` gets a chip beside the device name: `LAN` in the
  healthy tone or `Relay` in the signal tone, visible in every state including
  connecting, reconnecting, and failed. The subtitle becomes
  `<state> · <endpoint> · <route>`, for example
  `Live screen · 192.168.1.20 · direct` or `Live screen · relay.example · TURN`.
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
| Device advertisement | `DNSServiceRegister` from `<dns_sd.h>` inside `rctld` on a serial dispatch queue. | `NSNetService` (deprecated wrapper of the same responder); an embedded UDP 5353 responder (contingency only, if the system responder refuses a root daemon during qualification). |
| iOS discovery | `NWBrowser` with `.bonjourWithTXTRecord`, in `RctlRealtime` next to the LAN client. | `NetServiceBrowser` (deprecated); `DNSServiceBrowse` (no benefit on iOS 16). |
| Resolution | A bounded `NWConnection` to the service endpoint, reading the resolved `hostPort`; the literal then goes through the unchanged `LocalDeviceAddress` validation. | Handing service endpoints to `URLSession` (bypasses private-range and exact-target checks). |
| Instance name | The device's user-visible name from `UIDevice.name`, as AirPlay, printers, and `_ssh._tcp` do. Bonjour resolves collisions. | A generic `rctl` name (privacy-neutral but two iPads become `rctl` and `rctl (2)`, which defeats the feature). The unauthenticated `/v1/deviceinfo` already returns the name to anyone on the LAN, so the record adds no exposure. |
| Stable identity in TXT | Yes, a random 32-hex `id`, so saved entries survive address changes. | No identity (forces manual confirmation of every DHCP change). Trade-off: the identity is linkable across networks; documented under Privacy below. |
| Saved-address refresh | Before pairing: one-tap confirmation in the row. After pairing: automatic, because the verify handshake would fail against a hijacked address. | Silent refresh from an unsigned record (an mDNS spoofer could redirect input to itself). |
| IPv6 | Not advertised as connectable and not selected until the listener is dual-stack. IPv6-only results show `Unsupported network`. | Accepting ULA now (the daemon cannot accept it). |

### Service Contract

Service type `_rctl._tcp`, domain `local.`, SRV port equal to the bound HTTP
port, instance name equal to the device name (UTF-8, truncated at a character
boundary to 63 bytes). TXT record, one key per entry:

```text
txtvers=1
id=<random device identity, 32 hex characters>
pv=<protocol major>.<protocol minor>
auth=0|1                   # Increment C available on this device
fp=<unpadded base64url SHA-256 of the device SPKI>   # only when auth=1
```

Model, daemon version, and features are deliberately absent: they come from
the capabilities preflight, which is also where the client verifies them.
Client limits: 1 KiB aggregate TXT, 64 visible results, bounded strings,
malformed required keys reject the result before decoding anything else.

`id` is generated on first daemon start for every package, stored under the
existing plist lock, and reused as the relay `DeviceID` when a relay is
enrolled later. Installations that already have a relay `DeviceID` keep it.

`GET /v1/capabilities` gains an optional `device` object in protocol minor
1.2: `{ "device": { "id": "…", "name": "Kitchen iPad", "model": "iPad8,1" } }`.
Receivers ignore unknown fields within a major. The client compares
`device.id` with the TXT `id` after resolving; a mismatch marks the result
stale. This is a consistency check, not authentication.

Artifacts: `protocol/discovery-v1.md` (keys, limits, lifecycle),
`capabilities.schema.json` update, 1.1 and 1.2 capabilities fixtures,
synthetic TXT fixtures (valid, unknown key, oversized, malformed, duplicate
name), and `discovery_txt_bytes` in `protocol/limits.json`.

### Privacy

The TXT `id` is a stable identifier broadcast on every network the iPad
joins. The daemon already exposes far more to any LAN peer, and the product
documents that port 8080 is for trusted networks only, so this is accepted
rather than mitigated. It is revisited if the daemon ever gains a
network-aware policy. The device name is not a new exposure for the same
reason. Nothing in the record links to relay origins or credentials.

### Device Side

New `core/net/LocalDiscovery.{h,mm}`:

- `rctl_discovery_start(port, name, txt)` registers after `rctl_http_start`
  and the REST handler are installed; `rctl_discovery_stop()` deregisters on
  shutdown and on a policy transition. Relay-only mode never registers. A
  daemon crash drops the registration because the responder connection dies;
  restart must not accumulate entries.
- The name comes from the SpringBoard device-info query, with `rctl iPad` as
  the fallback while SpringBoard is not answering; the record is updated
  through `DNSServiceUpdateRecord` when the name arrives or changes.
- `kDNSServiceInterfaceIndexAny`; the responder chooses interfaces. Name
  conflicts, interface changes, and responder failures are logged with the
  `DNSServiceErrorType` and retried with bounded backoff (1 s doubling to
  60 s). None of them is fatal.
- `/v1/local_access` reports `"discovery": "advertising" | "off" | "error"`
  for the relay admin device page and diagnostics.
- Rootful and rootless linking of `libsystem_dnssd` is verified on device
  before the feature is enabled; a missing responder is a recoverable feature
  failure.

Host tests: TXT encoding limits and UTF-8 truncation. Device check: a Mac on
the same network sees the service with `dns-sd -B _rctl._tcp local.` and
resolves it with `dns-sd -L`.

### iOS Side

`RctlRealtime` gains transport-level types, no views:

- `LocalDeviceBrowser`: starts `NWBrowser` on demand, publishes bounded
  `[DiscoveredDevice]` (identity, name, protocol version, `auth`, `fp`,
  endpoints per interface), groups results from several interfaces by service
  identity, debounces churn, and maps `.waiting` with `kDNSServiceErr_PolicyDenied`
  to a `permissionDenied` state. Cancels on dismissal, backgrounding, and
  network changes; stale callbacks from a superseded browse are ignored.
- `LocalDeviceResolver`: resolves at most four results concurrently, each
  bounded to 5 s, prefers an RFC 1918 IPv4 literal, and reports
  `unsupportedAddressFamily` for IPv6-only results. Output is a
  `LocalDeviceAddress`, so every downstream check stays unchanged.

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
- `LocalDeviceProfile` v2 adds `deviceID: String?`, `source`, and `lastSeen`;
  `address` becomes last-known. Storage key `rctl.controller.local-devices.v2`
  with a one-time migration that keeps every v1 entry and its UUID. Duplicates
  are detected by identity when present, otherwise by exact endpoint; never by
  display name.
- `Nearby` rows show name, resolved address when available, and a
  `Discovered` chip; same-name devices are told apart by address. Tapping
  resolves if needed, runs the capabilities preflight, opens View mode, and
  offers `Save`. Saved devices that are currently advertised show `Online`
  from the browse result instead of a separate probe; a changed address shows
  `Address changed · Use` and is applied only on tap until the device is
  paired. `Add by address` stays in the same group and is emphasized when
  browsing is denied or finds nothing within 6 s.

### Manual Fallback

Manual entry is not deprecated. It is the only path for USB tunnels
(`iproxy`), multicast-filtering or client-isolated networks, and a device
whose responder failed. A manual entry later seen through discovery is merged
by identity, not duplicated. Discovery never edits a manual entry's address
without the confirmation above.

### Failure States

| Condition | Behavior |
|-----------|----------|
| Local Network permission denied | Callout with Settings; manual entry stays; no retry loop. |
| No results within 6 s | Quiet hint "No devices found. Add by address." Browsing continues. |
| Result resolves to a public, loopback, multicast, or link-local address | `Unsupported network`; not connectable; nothing saved. |
| IPv6-only result | `Unsupported network` with the IPv6 reason. |
| TXT `id` and capabilities `device.id` differ | Result marked stale and dropped; a saved entry keeps its last address. |
| Advertised major differs | `Incompatible` with both majors; not connectable. |
| Relay-only device | Not advertised; a saved entry shows `Offline`. |
| Result flood or oversized TXT | Rejected before decoding; at most 64 rows. |

### Tests And Acceptance

- Package tests: TXT bounds, identity matching, resolver rejection of every
  unsupported family and range, v1 store migration, deduplication rules,
  interface grouping, cancellation and stale-callback handling, and browser
  state mapping with an in-process `NWListener` advertising `_rctl._tcp` on
  loopback (the pattern in `RealtimeLifecycleTests`).
- App tests: `Nearby` rendering with synthetic results, denied state,
  address-change confirmation, and no capture or signaling during browsing.
- Physical matrix: two iPads with the same name on port 8080; DHCP change
  while the app is open; Relay-only toggle withdraws the service within 5 s;
  daemon restart re-registers once; rootful iOS 14 and rootless targets; iOS
  16, 17, and current on the controller; WAN disconnected; guest Wi-Fi and
  client isolation fall back to manual entry with the right message; VPN on
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
8080. The attacker cannot see the iPad screen, read root-owned files on the
iPad, or use the Secure Enclave key on the phone.

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

- Device: a long-term P-256 key generated by `rctld` on first start with
  Mbed TLS, stored as DER in a root-owned 0600 file beside the policy plist,
  under the same lock, independent of relay identity, preserved across package
  upgrades and rollback. The random `id` from Increment A stays the
  identifier; `fp` is the SHA-256 of the SubjectPublicKeyInfo; the controller
  pins the pair. A wipe creates a new identity that the controller treats as a
  different device.
- Controller: a non-exportable Secure Enclave P-256 key per paired device
  through `KeychainControllerStore` with a `local:<device-id>` namespace, so
  revoking or losing one device affects nothing else. Relay refresh
  credentials are never sent to a LAN endpoint.

### Trust Bootstrap

Two bootstrap paths produce the same controller record on the device.

Path 1, QR on the device screen (works without a relay):

```text
Controller                                             Device
  POST /v1/local/pairings
  {v:1, controller:{name,platform}, epk_c, scopes}  ->
                                                       creates pairing_id, secret (32 bytes), epk_d
                                                       SpringBoard overlay shows QR {v:1, id, p:pairing_id, s:secret}
                                                       and lists controller name + requested scopes, with Cancel
  <- {pairing_id, expires_at (<= 120 s), epk_d}
  scans QR with the existing scanner
  K = HKDF-SHA256(ECDH(epk_c, epk_d) || secret,
                  salt="rctl-local-pair-v1", info=pairing_id||epk_c||epk_d)
  POST /v1/local/pairings/{id}/claim
  {ct: AES-256-GCM_K(n=1, {spki_c, sig_c}, aad=pairing_id)} ->
                                                       wrong secret => AEAD failure; verifies sig_c; stores record
  <- {ct: AES-256-GCM_K(n=2, {device_id, spki_d, sig_d, controller_id, scopes})}
  verifies sig_d; requires SHA-256(spki_d) == fp when advertised; pins (id, fp)
```

Signed strings, UTF-8 with newline separators, mirroring `rctl-pair-v1`:

```text
sig_c: rctl-local-pair-v1\n<pairing_id>\n<epk_c>\n<epk_d>\n<b64url sha256(spki_c)>
sig_d: rctl-local-pair-v1\n<pairing_id>\n<epk_d>\n<epk_c>\n<b64url sha256(spki_d)>\n<b64url sha256(spki_c)>
```

Physical presence comes from the screen: only someone who sees the iPad can
read the secret. Fresh ECDH gives forward secrecy; the 256-bit secret makes
a man-in-the-middle fail without a PAKE. AES-GCM nonces are the 96-bit
big-endian message sequence and `K` is used once per direction. One active
pairing per device; a new request replaces and dismisses the previous one.
Limits: 3 requests per minute per source, 10 per minute total, five failed
claims lock pairing for 60 s. The secret lives only in daemon memory and on
the screen, is never logged or returned, and dies on claim, expiry, or
Cancel. Open decision 2 below considers an additional `Allow` tap on the iPad.

Path 2, relay-delegated grant (no device interaction):

A relay administrator, already trusted to approve devices and create
controllers, grants an existing relay controller local access to a device.
The relay sends the controller's SPKI, name, and scopes to the device over the
authenticated relay WebSocket as a `local_grant` message; the device stores
the same controller record. The controller learns the device identity (`id`,
`fp`) through the signed `GET /api/controller/devices` response, pins it, and
proceeds with the session handshake below. This adds no trust: a relay
compromise already yields full control through the tunnel. Relay-side scope
selection reuses the existing controller scope UI; the local scope set may be
narrower than the relay scopes but never wider.

Rejected: zero-interaction ownership (no trust anchor exists), first-claimant
wins (invariant 3 in the threat model), and a numeric PIN for v1 (needs a
reviewed PAKE such as SPAKE2+, and iOS exposes no public group arithmetic;
the screen makes a high-entropy QR simpler and stronger). A PIN path can be
added later without changing the identity model.

### Scopes

The scope set is the one in `CONTROLLER-AUTH.md` plus `local.manage` for
listing and revoking local controllers. The app requests `screen.view`,
`device.control`, `audio.listen`, `microphone.talk`, `camera`, `files.read`,
and `files.write` by default; `terminal`, `system.destructive`,
`device.update`, and `local.manage` are opt-in under `Advanced access` in the
pairing sheet. The overlay or the relay admin sees the requested set before
granting; the device grants exactly what was requested, never more.

### Session Channel

All authenticated local traffic runs through one WebSocket,
`GET /v1/local/session` (with the canonical `media=camera` query for camera
sessions). The upgrade is signed with the relay request-proof format so the
device rejects unknown controllers before allocating anything:

```text
X-RCTL-Controller: <controller_id>
X-RCTL-Timestamp: <unix-seconds>
X-RCTL-Nonce: <unpadded-base64url random 16..32 bytes>
X-RCTL-Signature: <unpadded-base64url ECDSA DER signature>
```

The signed bytes are the `rctl-request-v1` canonical string with the token
id replaced by `controller_id`. The device accepts 300 s of skew, keeps a
bounded nonce cache (512 entries or the skew window), and answers a skew
failure with `401` plus `device_time` so the client retries once with an
offset. A replayed nonce is a hard `401` without a hint.

After the upgrade, a two-round verify handshake authenticates both sides and
derives directional keys; every later envelope is sealed:

```text
controller -> {type:"verify", epk_c2, nonce_c}
device     -> {type:"verify", epk_d2, nonce_d, sig_d over transcript}
controller -> {type:"verify", sig_c over transcript}
K_s   = HKDF-SHA256(ECDH(epk_c2, epk_d2), salt="rctl-local-session-v1",
                    info=controller_id||device_id||nonce_c||nonce_d)
K_c2d = HKDF-Expand(K_s, "c2d");  K_d2c = HKDF-Expand(K_s, "d2c")
then: {type:"sealed", n:<sequence>, ct:<AES-256-GCM_Kdir(inner JSON, nonce=n, aad=n)>}
```

The transcript is every verify field in order; the controller checks
`sig_d` against the pinned `fp`. Each direction has its own key and a strictly
increasing sequence from 1; a gap, repeat, or wrap closes the socket. Inner
messages are the existing signaling envelopes plus management requests
(`controllers.list`, `controllers.revoke`), so `Term.mm` and
`RctlRealtimeSession` keep their state machines and gain a codec layer, and
no authenticated data ever rides plaintext REST. The device-side `open`
envelope carries the granted scopes, making `controller.scoped_sessions` the
single DataChannel gate on both the relay and the authenticated LAN path.

Because the SDP travels sealed, a man-in-the-middle cannot substitute the DTLS
fingerprint, and DTLS-SRTP then protects media and DataChannels end to end.

### Transport Decision

Sealed channel now, TLS later, for these reasons: it covers the whole native
surface with no certificate lifecycle, no trust-evaluation code in the app,
and no changes to the hand-written HTTP server's socket loop; and the browser
client, the only consumer that would benefit from TLS, cannot pin a device
certificate without a per-client profile install, so TLS alone would not make
the browser's LAN path authenticated. TLS on port 8080 with Mbed TLS (already
linked) is the recorded follow-up, triggered by browser local authentication
or by a need to protect legacy REST on the LAN. The sealed channel is
transport-agnostic and moves under TLS unchanged. Before implementation, a
short spike confirms URLSession WebSocket behavior with signed upgrades and
address changes on iOS 16, and Mbed TLS AES-GCM and ECDH on the iOS 14 daemon
runtime.

### Policy Modes And Enforcement

`LocalAccessEnabled` becomes a three-state `LocalAccessMode`; the boolean keeps
its meaning for existing installations.

| Mode | HTTP bind | Unauthenticated surface | Native controllers |
|------|-----------|-------------------------|--------------------|
| `lan-open` (today's default) | all interfaces | everything, as today | paired controllers use `/v1/local/session`; unpaired ones may still use `/ws/signal` |
| `lan-paired` | all interfaces | `/v1/capabilities`, `/v1/local/pairings*`, static files for a future browser login | only paired controllers with their scopes |
| `relay-only` | loopback | none from the network | none |

`lan-paired` is enforced at the request dispatcher, not per handler, against
the full inventory in Current Implementation: `/stream`, `/input`, `/key`,
`/config`, `/orient`, `/audio_test`, `/ws/signal`, `/ws/term`,
`/v1/pull_stream`, and every `/v1/*` path except the allow list return `403`
from the network. A host test asserts the inventory against the dispatcher
so a new endpoint cannot bypass the mode unnoticed. Switching to `lan-paired`
requires at least one paired controller with `local.manage`, a confirmation
token bound to `local_access:lan-paired`, and restarts like Relay-only.
`rctld --local-access lan` remains the SSH recovery to `lan-open`. Until the
browser client has local authentication, `lan-paired` makes the web page
unusable from the network; the admin page says so before confirming.

On the controller, a device with a pinned identity is always opened through
`/v1/local/session`. If the device answers without `local.auth` or with a
different identity, the app shows `Identity changed` with both fingerprints
and `Forget and pair again`; it never falls back to `/ws/signal` for a
pinned device.

### Revocation And Recovery

- `controllers.list` and `controllers.revoke` over the sealed channel require
  `local.manage`; revocation closes that controller's sessions within one
  second. Relay administrators reach the same operations through the
  authenticated relay tunnel, so a lost phone is revocable without the phone.
- The app lists paired devices with fingerprint, scopes, and `Forget`, which
  deletes the pin and the Secure Enclave key.
- Device key replacement (wipe or explicit reset through the SSH CLI) requires
  re-pairing every controller; the daemon never rotates the key silently.
- Package upgrade and rollback preserve the key file and controller records;
  a downgrade to a daemon without `local.auth` leaves `lan-paired` devices
  reachable only through `rctld --local-access lan` over SSH, which the
  release notes must state.
- Audit: pairing creation, claim success or failure, grants, and revocations
  are logged with controller ids and source addresses, never secrets or keys.

### Contracts And Fixtures

- `protocol/local-auth-v1.md`: pairing, relay grant, signed upgrade, verify
  handshake, sealed envelope, limits, state diagrams, and error codes.
- `protocol/schemas/local-auth.schema.json`; `signaling-v1.md` gains the
  sealed transport section without changing inner messages; the relay
  device protocol gains `local_grant`.
- Fixtures under `protocol/fixtures/local-auth/`: golden pairing and verify
  exchanges with test keys, wrong-secret claim, replayed nonce, mismatched
  fingerprint, out-of-order sequence, oversized and malformed messages, and a
  future-minor sealed envelope.
- `protocol/limits.json` adds `local_pairing_json_bytes` and
  `sealed_envelope_bytes`. Protocol minor becomes 1.2 with feature
  `local.auth` alongside Increment A's `device` object.

### Tests And Acceptance

- Host tests: Mbed TLS vectors shared with the Swift tests, nonce cache
  bounds, rate limits and lockout, policy transitions under the plist lock,
  dispatcher inventory, and revocation closing sessions.
- Swift package tests: the same vectors, key namespacing, pinning,
  identity-change detection, sequence enforcement, and downgrade refusal.
- Security cases: man-in-the-middle during pairing, replayed claim, replayed
  upgrade, SDP tampering under the sealed channel, look-alike service with a
  copied TXT record, scope escalation by editing the request, revoked
  controller mid-session, skew beyond the window, and a legacy endpoint
  probed in `lan-paired` mode.
- Physical: pairing from an overlay scan in under 30 s; relay-delegated grant
  end to end; pairing survives daemon restart and package upgrade;
  `lan-paired` blocks an unpaired phone and the browser with the documented
  message; relay-side revocation; `Forget` then re-pair; identity change after
  a wipe.

Acceptance: an attacker on the same network cannot claim ownership by racing,
spoofing Bonjour, replaying a grant, or using an overlooked legacy endpoint; a
device in `lan-paired` mode cannot be controlled by an unpaired client; the
relay path and `lan-open` behavior are unchanged for existing installations.

## Sequencing And Commits

```text
B. Access path      model + header + tools sheet                        (no protocol change)
A. Discovery        contract -> daemon identity + advertiser -> iOS browser/resolver -> Devices UI
C. Local pairing    review gate -> contract -> daemon identity/pairing -> session channel
                    -> app pairing + pinning -> relay grant -> lan-paired mode
```

Suggested commits, each verified on its own:

1. `feat(ios): persistently identify session access path`
2. `docs(protocol): define bounded LAN discovery records`
3. `feat(daemon): advertise available LAN control with Bonjour`
4. `feat(ios): discover and connect to local devices`
5. `test(lan): qualify discovery and lifecycle recovery`
6. `docs(protocol): specify authenticated local pairing` (review gate)
7. `feat(daemon): add device identity and local pairing`
8. `feat(ios): pair, pin, and open sealed local sessions`
9. `feat(relay): delegate local grants to paired controllers`
10. `feat(daemon): add the lan-paired access mode`

Unrelated concurrent input and web changes stay out of these commits. Plan
edits are not deployed.

## Open Decisions For The Owner

1. Ship `lan-paired` with pairing, or hold it until the browser client has
   local authentication so the mode does not disable the web page.
2. Require an `Allow` tap on the iPad overlay in addition to visibility,
   defeating a camera pointed at the screen at the cost of one step.
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
- HomeKit Accessory Protocol pair-verify, prior art for the
  ephemeral-then-sign session handshake
