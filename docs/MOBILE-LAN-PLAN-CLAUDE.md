# LAN Discovery, Access-Path Visibility, And Authenticated Local Pairing

Status: implementation plan. Nothing in this document is shipped. It extends
the implemented direct-IP flow described in [`MOBILE-LAN.md`](MOBILE-LAN.md)
and follows the work rules, contract discipline, and qualification gates of
[`MOBILE-PLAN.md`](MOBILE-PLAN.md). Product behavior and visual rules for the
Devices screen live in [`MOBILE-DESIGN.md`](MOBILE-DESIGN.md).

The plan has three increments that ship independently, in order:

| Increment | Outcome | Protocol impact |
|-----------|---------|-----------------|
| A. Discovery | Devices on the same network appear without typing an IP. Manual address stays as the fallback. | Additive: `_rctl._tcp` service, optional `device` object in capabilities (minor 1.2). |
| B. Access path | An open session always shows whether it runs over LAN or Relay, with the concrete endpoint and ICE path. | None. |
| C. Authenticated local pairing | A discovered device can be proven to be yours, and the device accepts only paired, scoped controllers. | New `local.auth` feature, `/v1/local/*` endpoints, sealed signaling envelope (minor 1.2). |

A and B are convenience and honesty features on top of the existing
trusted-network model. C changes the trust model and is designed separately,
because Bonjour discovery by itself proves nothing about who answers.

## Goals And Non-Goals

Goals:

- remove IP entry from the common case on a home network;
- keep manual entry as a first-class fallback for mDNS-hostile networks, USB
  tunnels, and support scenarios;
- make the active access path impossible to misread while a session is open;
- give the native controller a way to authenticate the iPad and the iPad a way
  to authenticate and scope the controller, on a plaintext LAN with an active
  attacker;
- reuse the existing controller identity, request-proof format, scope set, and
  `controller.scoped_sessions` gating instead of inventing parallel concepts.

Non-goals for these increments:

- automatic fallback between Relay and LAN in either direction;
- authentication for the browser client served on port 8080 (a separate item;
  the policy model below leaves room for it);
- hostname-based manual entry, link-local IPv6, or peer-to-peer Wi-Fi;
- discovery across subnets or through the relay;
- Android implementation (parity is tracked in `MOBILE-PLAN.md`, Phase 5).

## Current State

Facts the plan relies on, taken from the code on 2026-09-10:

- `rctld` binds `0.0.0.0:8080` when `LocalAccessEnabled` is true and
  `127.0.0.1:8080` in Relay-only mode (`core/config/LocalAccess.mm`,
  `daemon/main.mm`). The policy is stored in
  `/var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist` under an
  atomic lock shared with relay approval.
- `DeviceID` is generated only when a relay entry exists (`core/net/RelayClient.mm`);
  a public LAN-only package has no stable device identity today.
- Direct-LAN signaling is `GET /ws/signal` in `core/net/Term.mm`; the device is
  the offerer, the `open` envelope omits scopes, and the session receives every
  DataChannel (full trust).
- The daemon already links Mbed TLS 3.6.6 (`third_party/webrtc/build-ios.sh`)
  for DTLS-SRTP, so P-256 ECDH/ECDSA, HKDF, and AES-GCM are available on the
  device without a new dependency.
- The SpringBoard tweak already presents `UIWindow` overlays above alerts
  (`springboard/rctlsbcap.xm`), so the device can show a pairing QR on its own
  screen.
- The iOS app validates every local target through `LocalDeviceAddress`
  (private IPv4 or bracketed IPv6 ULA only), fetches capabilities through an
  isolated `URLSession`, and permits plaintext WebSocket only for the exact
  validated endpoint. The controller identity is a non-exportable P-256 key
  per relay (`KeychainControllerStore`). The relay request proof is
  `rctl-request-v1` (`CONTROLLER-AUTH.md`).
- No mDNS or Bonjour code exists anywhere in the repository.

## Increment A: Discovery

### Decisions

| Question | Decision | Alternatives considered |
|----------|----------|-------------------------|
| Device-side advertisement | `DNSServiceRegister` from `<dns_sd.h>` on a dedicated dispatch queue inside `rctld`. | `NSNetService` (deprecated, same responder underneath); an embedded mDNS responder on UDP 5353 with `SO_REUSEPORT` (kept as a contingency if the system responder refuses a root daemon during qualification). |
| iOS discovery | `NWBrowser` with `.bonjourWithTXTRecord(type:domain:)` inside the `RctlRealtime` module, which already owns the LAN transport policy. | `NetServiceBrowser` (deprecated); `DNSServiceBrowse` C API (no advantage over `NWBrowser` on iOS 16). |
| Address resolution | Open a short-lived `NWConnection` to the service endpoint, read the resolved `hostPort` from `currentPath.remoteEndpoint`, close it, and feed the literal into the existing `LocalDeviceAddress` validation. | Using the service endpoint directly with `URLSession` (would bypass private-range validation and the exact-target WebSocket policy). |
| Identity for saved entries | Saved local devices are keyed by the advertised device identity; the address becomes a last-known cache refreshed from discovery. | Keep IP as the key (breaks on every DHCP change, which is the problem being solved). |
| Trust | Discovery is a hint only. Capabilities preflight remains mandatory, and nothing in a TXT record grants access. | Trusting TXT-advertised features (spoofable by anyone on the LAN). |

### Service Contract

Service type `_rctl._tcp`, domain `local.`, port 8080 (or the bound port),
instance name equal to the user-visible device name. Name conflicts are
resolved by the responder (`Kitchen iPad (2)`); the daemon logs the final name.

TXT record, one key/value per entry, total under 400 bytes:

```text
txtvers=1
id=<stable device identity, 32 hex characters>
name=<display name, UTF-8, at most 63 bytes>
model=<hardware model such as iPad8,1>
pv=<protocol major>.<protocol minor>
dv=<rctld version>
auth=0|1           # 1 once Increment C is available on this device
fp=<unpadded base64url SHA-256 of the device SPKI>   # only when auth=1
```

`id` is generated on first daemon start for every package, stored under the
existing atomic plist lock, and reused as the relay `DeviceID` when a relay is
enrolled later, so a device has one identity across LAN and relay. Existing
installations that already have a relay `DeviceID` keep it.

`GET /v1/capabilities` gains an optional `device` object in protocol minor 1.2:

```json
{ "device": { "id": "…", "name": "Kitchen iPad", "model": "iPad8,1" } }
```

Receivers ignore unknown fields within a major, so 1.1 clients are unaffected.
The controller cross-checks `device.id` against the TXT `id` after resolving,
which catches stale mDNS cache entries and address reuse without claiming any
cryptographic guarantee.

Contract artifacts: `protocol/discovery-v1.md` (TXT keys, limits, lifecycle),
`protocol/schemas/capabilities.schema.json` update, fixtures under
`protocol/fixtures/capabilities/` for a 1.2 response and a 1.1 response, and a
`discovery_txt_bytes` entry in `protocol/limits.json`.

### Device Side

New `core/net/LocalDiscovery.{h,mm}`:

- `rctl_discovery_start(port, name, txt)` registers the service after
  `rctl_http_start` succeeds; `rctl_discovery_stop()` deregisters before the
  HTTP server is torn down. Relay-only mode never registers. A daemon crash
  drops the registration automatically because the responder connection dies.
- The display name comes from the SpringBoard device-info query already used by
  `/v1/deviceinfo`, with `rctl iPad` as the fallback when SpringBoard is not
  yet answering; the record is updated with `DNSServiceUpdateRecord` when the
  name arrives or changes.
- `kDNSServiceInterfaceIndexAny` with the responder deciding interfaces; the
  daemon does not enumerate interfaces itself.
- Errors are logged with the `DNSServiceErrorType` and retried with backoff
  (1 s doubling to 60 s), never fatal to the daemon.
- `/v1/local/access` reports `"discovery": "advertising" | "off" | "error"`
  so the relay admin device page and diagnostics can show it.

Host test: a Mac on the same network sees the service with
`dns-sd -B _rctl._tcp local.` and resolves it with `dns-sd -L`. A unit test
covers TXT encoding limits and name truncation at a UTF-8 boundary.

### iOS Side

`RctlRealtime` gains:

- `LocalDeviceBrowser` (`@MainActor`, `ObservableObject`): starts `NWBrowser`
  on demand, publishes `[DiscoveredDevice]` (identity, name, model, protocol
  version, `auth`, `fp`, endpoint, interface), debounces result churn, and maps
  `.waiting(error)` with `kDNSServiceErr_PolicyDenied` to a `permissionDenied`
  state. Browsing runs only while the Devices screen is visible and the scene
  is active.
- `LocalDeviceResolver`: resolves one result with a bounded `NWConnection`
  (5 s), prefers an RFC 1918 IPv4 literal, accepts a ULA literal, and rejects
  link-local IPv6 with an explicit `unsupportedAddressFamily` error. The result
  is a `LocalDeviceAddress`, so every downstream check stays unchanged.

The app:

- `Info.plist` adds `NSBonjourServices` with `_rctl._tcp` and updates
  `NSLocalNetworkUsageDescription` to mention discovery.
- `LocalDeviceProfile` v2 adds `deviceID: String?`, `source: manual|discovered`,
  and `lastSeen`. `address` becomes last-known. Storage key
  `rctl.controller.local-devices.v2` with a one-time migration from v1 that
  keeps every entry (`deviceID` nil until first successful preflight reports
  one). Deduplication is by `deviceID` when present, otherwise by address.
- Devices screen: a `Nearby` group lists discovered devices that are not saved
  yet (name, model, `Discovered` chip). Saved devices whose identity is
  currently advertised show `Online` and silently refresh their cached address;
  saved devices that are not advertised keep the existing probe-based chip.
  Tapping a nearby device resolves, preflights, opens View mode, and offers
  `Save`. `Add by address` remains in the same group and is highlighted when
  browsing is denied or finds nothing after 6 s.
- Permission states: first browse triggers the system Local Network prompt.
  Denied permission shows a callout with `Open Settings` and keeps manual entry
  visible. Manual entry also needs the permission; the message says so instead
  of guessing at a timeout.

### Manual Fallback Rules

Manual address entry is not deprecated. It is the only path for USB tunnels
(`iproxy`), networks that filter multicast, client-isolated Wi-Fi, and devices
whose responder failed. A manually added device later seen through discovery is
merged by `deviceID` rather than duplicated. Discovery never edits a manual
entry's address unless the identities match.

### Failure States

| Condition | Behavior |
|-----------|----------|
| Local Network permission denied | `Nearby` shows a callout with Settings; manual entry stays. No retry loop. |
| No results within 6 s | Quiet hint: "No devices found. Add by address." Browsing continues. |
| Result resolves to a public or link-local address | Row shows `Unsupported network`; not connectable; no address is saved. |
| TXT `id` and capabilities `device.id` differ | Treat as stale; drop the cached address, keep the entry, show `Address changed`. |
| Advertised protocol major differs | Row shows `Incompatible` with both majors; not connectable. |
| Relay-only device | Not advertised; a saved entry shows `Offline` with the existing hint. |
| Duplicate names | Rows show the model and last octet of the address to disambiguate. |

### Tests And Qualification

- Package tests: TXT parsing bounds, identity matching, resolver rejection of
  link-local and public literals, migration of the v1 store, deduplication by
  identity, and browser state mapping using an in-process `NWListener` that
  advertises `_rctl._tcp` on loopback (the pattern already used in
  `RealtimeLifecycleTests`).
- App tests: `Nearby` rendering with synthetic results, denied-permission
  state, and cached-address refresh for a saved identity.
- Physical qualification (release gate): two iPads with the same name; DHCP
  lease change while the app is open; Relay-only toggle withdraws the service
  within 5 s; daemon restart re-registers; iOS 16, 17, and current on the
  controller; a client-isolated network falls back to manual entry with the
  correct message; simulator on the Mac's network sees a real device.

Exit criteria: a fresh install on a home network connects to an iPad without
typing an address; a saved device survives an address change without user
action; no code path trusts a TXT value for access decisions.

## Increment B: Access Path Always Visible

The session header currently collapses the path into the state label ("Live
screen"), so a user cannot tell LAN from Relay once connected. This increment
makes the path a persistent, semantic element.

- `RemoteSessionModel` publishes `accessPath` (`lan(LocalDeviceAddress)` or
  `relay(host: String)`) from the connection target, and `transportDetail`
  (`direct`, `serverReflexive`, `relayed`, `unknown` plus round-trip time)
  sampled every 3 s from the selected ICE candidate pair in the PeerConnection
  statistics report. Sampling stops when the session suspends.
- `RemoteSessionHeader` shows a chip next to the device name: `LAN` in the
  healthy tone or `Relay` in the signal tone, present in every state including
  reconnecting and failed. The subtitle becomes `<state> · <endpoint> ·
  <transport>`, for example `Live screen · 192.168.1.20 · direct` or
  `Live screen · relay.example · TURN`. The chip is never removed while the
  screen is open.
- `RemoteToolsSheet` adds a read-only `Connection` block with path, endpoint,
  transport, RTT, protocol version, and whether the session is scoped.
- Accessibility: the chip reads "Connection path: local network" or
  "Connection path: relay". Colors are never the only signal.
- Invariant preserved: no automatic path change; a relay failure never shows
  `LAN`, and vice versa.

Tests: header snapshot for both paths in every session state at the largest
accessibility size; a model test that `accessPath` never changes for the life
of a session; a statistics-mapping test for each candidate-pair type.

## Increment C: Authenticated Local Pairing

### Threat Model

The network is hostile: an attacker can see, modify, and inject LAN traffic,
run their own `_rctl._tcp` service with any name and TXT, and reach port 8080.
The attacker cannot see the iPad's screen and cannot read files owned by root
on the iPad or the Secure Enclave key on the phone.

Required properties:

1. The controller connects only to the device it paired with, or fails
   loudly. A look-alike device or a man-in-the-middle cannot obtain a session.
2. The device accepts sessions only from paired controllers, limited to the
   scopes granted at pairing, and can revoke any controller.
3. Pairing secrets never travel in clear over the LAN and cannot be brute
   forced offline from captured traffic.
4. Signaling cannot be altered in transit; in particular the DTLS fingerprint
   in the SDP is bound to the authenticated channel.
5. Nothing about pairing weakens the relay path or the unauthenticated path
   for installations that keep it.

Out of scope: an attacker who already has root on the iPad, and confidentiality
of media (already provided by DTLS-SRTP once signaling is authenticated).

### Identities

- Device: a long-term P-256 key generated by `rctld` on first start with
  Mbed TLS, stored as DER under the existing plist lock in a root-owned file
  with mode 0600 next to the relay configuration. The random identity `id`
  from Increment A stays the stable identifier; `fp` is the SHA-256 of the
  key's SubjectPublicKeyInfo, and the controller pins the pair (`id`, `fp`).
  Reinstalling the package keeps both; a wipe creates a new identity, which
  the controller must treat as a different device.
- Controller: a non-exportable P-256 key in the Secure Enclave, created per
  paired device through the existing `KeychainControllerStore` with a
  `local:<device-id>` namespace, so losing or revoking one device does not
  affect relay identities or other devices.

### Pair-Setup Ceremony

The ceremony proves physical presence with a QR code that only the iPad's
screen shows, binds fresh ephemeral keys to that secret, and exchanges pinned
long-term keys inside an authenticated encrypted channel. It needs no PAKE
because the secret has 256 bits of entropy.

```text
Controller                                             Device
  POST /v1/local/pairings
  {v:1, controller:{name,platform}, epk_c, scopes}  ->
                                                       generates pairing_id, secret (32 bytes), epk_d
                                                       shows QR on screen: {v:1, id, p:pairing_id, s:secret}
                                                       overlay lists controller name + requested scopes
  <- {pairing_id, expires_at (<= 120 s), epk_d}
  scans QR with the existing scanner
  K = HKDF-SHA256(ECDH(epk_c, epk_d) || secret,
                  salt="rctl-local-pair-v1", info=pairing_id||epk_c||epk_d)
  POST /v1/local/pairings/{id}/claim
  {ct: AES-256-GCM_K(n=1, {spki_c, sig_c}, aad=pairing_id)} ->
                                                       decrypts (wrong secret => authentication failure),
                                                       verifies sig_c, stores controller record
  <- {ct: AES-256-GCM_K(n=2, {device_id, spki_d, sig_d, controller_id, scopes})}
  verifies sig_d, checks SHA-256(spki_d) == fp from TXT when present,
  pins spki_d for device_id in Keychain
```

Signed strings, UTF-8 with newline separators, mirroring `rctl-pair-v1`:

```text
sig_c over: rctl-local-pair-v1\n<pairing_id>\n<epk_c>\n<epk_d>\n<b64url sha256(spki_c)>
sig_d over: rctl-local-pair-v1\n<pairing_id>\n<epk_d>\n<epk_c>\n<b64url sha256(spki_d)>\n<b64url sha256(spki_c)>
```

Rules:

- AES-256-GCM nonces are the 96-bit big-endian message sequence; the pairing
  key `K` is used exactly once per direction (`n=1` and `n=2`).
- One active pairing per device; a new request replaces the previous one and
  dismisses its overlay. Requests are rate limited to 3 per minute per source
  address and 10 per minute in total. Five failed claims lock pairing for 60 s.
- The secret exists only in daemon memory and on the screen; it is never
  logged, never returned by any endpoint, and is destroyed on claim, expiry,
  or dismissal. The overlay shows a Cancel button on the iPad.
- Scopes come from the existing set in `CONTROLLER-AUTH.md` plus a new
  `local.manage` scope for listing and revoking local controllers. The app
  requests `screen.view`, `device.control`, `audio.listen`,
  `microphone.talk`, `camera`, `files.read`, and `files.write` by default;
  `terminal`, `system.destructive`, `device.update`, and `local.manage` are
  opt-in toggles under `Advanced access` in the pairing sheet. The person
  holding the iPad sees the requested set on the overlay before scanning;
  the device grants exactly what was requested, never more.
- The controller refuses to pair when the TXT `fp` is present and does not
  match `spki_d`, and refuses when `device_id` in the claim response differs
  from the identity it discovered.

Why not a PIN with a PAKE: SPAKE2+ or SRP would allow a six-digit code, but
iOS exposes no public elliptic-curve group arithmetic or big-integer API, so a
vetted implementation would have to be vendored; the iPad has a screen, so a
high-entropy QR is both simpler and stronger. A PIN path can be added later
without changing the identity model.

### Session Authentication

Every authenticated local request reuses the relay request-proof format so the
device-side verifier mirrors the relay's:

```text
X-RCTL-Controller: <controller_id>
X-RCTL-Timestamp: <unix-seconds>
X-RCTL-Nonce: <unpadded-base64url random 16..32 bytes>
X-RCTL-Signature: <unpadded-base64url ECDSA DER signature>
```

The signed bytes are the `rctl-request-v1` canonical string with the token id
replaced by `controller_id`. The device accepts a 300 s skew, keeps a bounded
nonce cache (512 entries or the skew window, whichever fills first), and
answers a skew failure with `401` and `device_time` so the client can retry
once with a corrected offset. Nonce replay is a hard `401` without a hint.

Authenticated signaling uses a new endpoint, `GET /v1/local/signal` (with the
canonical `media=camera` query), signed like any GET. After the upgrade the
peers run a two-message verify handshake, then seal every signaling envelope:

```text
controller -> {type:"verify", epk_c2, nonce_c}
device     -> {type:"verify", epk_d2, nonce_d, sig_d over transcript}
controller -> {type:"verify", sig_c over transcript}
K_s = HKDF-SHA256(ECDH(epk_c2, epk_d2), salt="rctl-local-session-v1", info=controller_id||device_id||nonce_c||nonce_d)
K_c2d, K_d2c = HKDF-Expand(K_s, "c2d"), HKDF-Expand(K_s, "d2c")
thereafter: {type:"sealed", n:<sequence>, ct:<AES-256-GCM_Kdir(envelope JSON, nonce=n, aad=n)>}
```

The transcript is every verify field in order. Each direction has its own key
and a strictly increasing sequence starting at 1; a gap, repeat, or wrap
closes the socket. The sealed
envelope carries the existing signaling messages unchanged, so `Term.mm` and
`RctlRealtimeSession` keep their state machines and only gain a codec layer.
The device-side `open` envelope carries the controller's granted scopes, which
makes `controller.scoped_sessions` the single gate for DataChannel exposure on
both the relay and the authenticated LAN path.

Because the SDP travels sealed, a man-in-the-middle cannot substitute the DTLS
fingerprint, and DTLS-SRTP then protects media and DataChannels end to end.
Local TLS on port 8080 is therefore not required for the native controller. It
stays a documented follow-up (Mbed TLS is already linked) for browser clients
and defense in depth.

### Policy Modes

`LocalAccessEnabled` becomes a three-state `LocalAccessMode` with a
backward-compatible reading of the boolean:

| Mode | HTTP bind | Unauthenticated surface | Native controllers |
|------|-----------|-------------------------|--------------------|
| `lan-open` (current default) | all interfaces | everything, as today | paired controllers use `/v1/local/signal`; unpaired controllers may still use `/ws/signal` |
| `lan-paired` | all interfaces | `/v1/capabilities`, `/v1/local/pairings*`, static assets | only paired controllers with their scopes |
| `relay-only` | loopback | none from the network | none |

Switching to `lan-paired` requires at least one paired controller with
`local.manage`, a confirmation token bound to `local_access:lan-paired`, and
the same restart behavior as Relay-only. `rctld --local-access lan` remains
the SSH recovery path and returns to `lan-open`. The browser client is not
usable from the network in `lan-paired` mode until it has its own local
authentication; the admin page says so before the switch is confirmed.

On the controller side, a device with a pinned identity is always opened
through `/v1/local/signal`. If the device answers without `local.auth` or with
a different identity, the app shows `Identity changed` with the two
fingerprints and a `Forget and pair again` action; it never falls back to the
unauthenticated endpoint for a device it has pinned.

### Management And Revocation

- `GET /v1/local/controllers` (requires `local.manage`) lists id, name,
  platform, scopes, created and last-seen times; `DELETE /v1/local/controllers/{id}`
  revokes and closes that controller's sessions within one second.
- Relay administrators reach the same endpoints through the existing device
  proxy, so a lost phone can be revoked from the relay admin page.
- The controller lists paired devices in Settings with fingerprint, scopes,
  and `Forget`, which deletes the pin and the Secure Enclave key.
- Audit: the daemon logs pairing creation, claim success or failure, and
  revocation with controller ids and source addresses, never secrets or keys.

### Contracts And Fixtures

- `protocol/local-auth-v1.md`: pairing, request proof, verify handshake,
  sealed envelope, limits, and state diagrams.
- `protocol/schemas/local-auth.schema.json` for pairing requests and responses,
  verify messages, and sealed envelopes; `protocol/signaling-v1.md` gains the
  sealed transport section without changing inner messages.
- Fixtures under `protocol/fixtures/local-auth/`: golden pairing exchange with
  test keys, malformed and oversized messages, replayed nonce, wrong-secret
  claim, mismatched fingerprint, and a future-minor sealed envelope.
- `protocol/limits.json` adds `local_pairing_json_bytes` and
  `sealed_envelope_bytes`. Protocol minor becomes 1.2 with features
  `local.auth` and, once Increment A ships, the `device` capabilities object.

### Tests And Qualification

- Host tests (`make test`): Mbed TLS pairing vectors shared with the Swift
  package tests, nonce cache bounds, rate limits, lockout, policy transitions
  with the plist lock, and revocation closing sessions.
- Swift package tests: the same vectors, Secure Enclave key namespacing,
  fingerprint pinning, identity-change detection, sealed-envelope sequence
  enforcement, and refusal to downgrade.
- Security cases: man-in-the-middle during pairing (wrong secret), replayed
  claim, replayed signed request, SDP tampering under a sealed channel, forged
  `_rctl._tcp` service with a copied TXT record, scope escalation by editing
  the request, revoked controller mid-session, clock skew beyond the window.
- Physical qualification: pair from a scan of the iPad overlay in under 30 s;
  pairing survives daemon restart; `lan-paired` blocks an unpaired phone and
  the browser with the documented message; relay admin revocation; `Forget`
  on the phone followed by re-pairing; identity change after a wipe.

Exit criteria: a controller cannot open a session with a device it did not
pair with, a device in `lan-paired` mode cannot be controlled by an unpaired
client, and the relay path and `lan-open` behavior are byte-for-byte unchanged
for existing installations.

## Sequencing And Dependencies

```text
A. Discovery            device identity + advertisement -> NWBrowser + resolver -> Devices UI
B. Access path          independent of A; can land first
C. Local pairing        needs A's identity; ships as protocol minor 1.2 with A's capability change
```

Recommended order: B (one to two days, no protocol change), then A (device
and app in parallel, one contract review), then C after A is qualified on
physical devices. Each increment lands as its own commit series with docs and
fixtures, and none of them changes the relay contract.

## Open Decisions For The Owner

1. Whether `lan-paired` should ship in the same release as pairing, or wait
   until the browser client has local authentication so the mode does not
   disable the web page.
2. Whether the pairing overlay on the iPad should also require a tap on the
   iPad (`Allow`) in addition to being visible, which would defeat a camera
   pointed at the screen at the cost of one more step.
3. Whether relay administrators should be able to pre-approve local
   controllers without a physical scan; the current plan says no.

## References

- Apple, [TN3179 Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- Apple, [NWBrowser](https://developer.apple.com/documentation/network/nwbrowser) and
  [DNS Service Discovery C API](https://developer.apple.com/documentation/dnssd)
- RFC 6762 (Multicast DNS), RFC 6763 (DNS-Based Service Discovery, TXT rules)
- RFC 5869 (HKDF), RFC 9700 section 4.14.2 (sender-constrained tokens, as used
  by the relay path)
- Apple HomeKit Accessory Protocol pair-verify structure, used here as prior
  art for the ephemeral-then-sign session handshake
