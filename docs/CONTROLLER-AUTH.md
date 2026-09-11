# Native Controller Authentication

Status: protocol contract for native controller pairing and relay authorization.
Browser admin cookies and device credentials remain separate and unchanged.

## Trust Model

An authenticated relay administrator authorizes a controller once. The native
application creates a non-exportable P-256 signing key and never stores the
relay admin password. A short-lived, single-use pairing secret authorizes only
creation of the controller and its preselected scopes. It cannot administer the
relay or authenticate after consumption.

Controller authorization requires both an opaque token and proof of possession
of the registered private key. A copied access or refresh token is insufficient
without that key. Controller credentials never appear in URLs, query strings,
logs, audit details, QR analytics, fixtures, or crash metadata.

## Scopes

Version 1 defines:

```text
screen.view
device.control
audio.listen
microphone.talk
camera
files.read
files.write
terminal
system.destructive
device.update
```

`relay.admin` is deliberately absent. Native controllers cannot create other
controllers, approve devices, change relay configuration, or read the complete
admin audit log. Unknown scopes are rejected when a pairing is created; a newer
client hides features whose scopes or capabilities are absent.

## Pairing

The administrator creates a pairing with a controller name, explicit scopes,
and a lifetime from one through ten minutes. The relay returns one QR payload:

```json
{
  "v": 1,
  "origin": "https://relay.example",
  "pairing_id": "pair_...",
  "secret": "...",
  "expires_at": 1787600000,
  "protocol_major": 1,
  "relay_id": "base64url-stable-public-identifier"
}
```

The QR is shown only in the authenticated admin surface. `origin` is the exact
configured HTTPS origin without credentials, query, or fragment. `relay_id` is
a random stable public identifier stored by the relay; it is not derived from a
server secret. The app displays the origin and relay identity before committing
and pins both in the resulting profile.

The admin client renders the QR locally; the payload is never sent to an image,
analytics, or shortening service. The plaintext secret exists only in the
create response and the current browser tab. Closing an unused code revokes it
immediately through `POST /api/admin/controller-pairings/{id}/revoke`; otherwise
it expires automatically after at most ten minutes.

The app generates a P-256 signing key and submits its X.509 SubjectPublicKeyInfo
DER as unpadded base64url together with platform, name, pairing secret,
`relay_id`, and a DER-encoded ECDSA/SHA-256 proof. The signed bytes are UTF-8:

```text
rctl-pair-v2\n
<relay-id>\n
<configured-origin-without-trailing-slash>\n
<pairing-id>\n
<pairing-secret>\n
<controller-name>\n
<platform>\n
<base64url-sha256-public-key>
```

Names are trimmed before signing. Platform is `ios` or `android`. The relay
requires `relay_id` to equal its persisted public identity and verifies the
proof against its configured origin, never an origin supplied in the claim.
Missing, empty, substituted identities and old `rctl-pair-v1` proofs fail before
consuming the pairing or creating credentials. The relay validates the public
key, signature, secret, origin-owned pairing record,
expiry, and unused state in one database transaction. At most one concurrent
claim succeeds. Pairing secrets are stored as keyed hashes and are unrecoverable
after the create response.

The claim response includes `relay_id`. The client requires it to match the QR
before saving a profile or credential; missing response identities fail closed.
The QR envelope remains version 1: its fields did not change. The claim proof
is version 2 and deliberately has no downgrade fallback. Upgrade both relay
and native controller before creating new pairings. Existing paired profiles,
request proofs, access tokens, and refresh tokens are unchanged and do not
require re-pairing. A previously saved profile with a manually changed ID is
not automatically merged with another profile.

Identity binding prevents accidental/substituted identities at an honest
relay; it does not make a QR from an unknown party trustworthy. A malicious
relay can claim any public ID. Verify the HTTPS origin before pairing, keep QR
secrets private, and revoke any pairing exposed to another person. Knowing only
`relay_id` does not grant access.

## Tokens And Request Proof

Claim returns an access token valid for ten minutes and a refresh token with a
thirty-day inactivity lifetime. Tokens are independent high-entropy opaque
values stored only as keyed hashes. The refresh token is sender-constrained to
the controller's registered P-256 key. Successful refresh extends its inactivity
expiry and atomically replaces every outstanding access token for that
controller; the refresh secret itself remains stable.

This follows the sender-constrained refresh-token option in
[RFC 9700 section 4.14.2](https://www.rfc-editor.org/rfc/rfc9700.html#section-4.14.2).
A copied refresh token cannot be used without a fresh proof from the registered
private key. Keeping the bound token stable also makes an ambiguously completed
refresh recoverable after process death without storing recoverable replacement
secrets on the relay.

Every controller request includes:

```text
Authorization: Bearer <token-id>.<token-secret>
X-RCTL-Timestamp: <unix-seconds>
X-RCTL-Nonce: <unpadded-base64url random 16..32 bytes>
X-RCTL-Signature: <unpadded-base64url ECDSA DER signature>
```

The signed bytes are UTF-8 and use the URL exactly as sent by the rctl client:

```text
rctl-request-v1\n
<token-id>\n
<timestamp>\n
<nonce>\n
<uppercase-method>\n
<escaped-path>\n
<canonical-query>\n
<unpadded-base64url-sha256-body>
```

The canonical query is RFC 3986 key/value encoding sorted by encoded key then
encoded value. Requests without a query sign an empty line. WebSocket upgrades
use `GET` with an empty body. The relay accepts a bounded clock skew, atomically
records each `(controller, nonce)`, and rejects replay. Signature verification
occurs before scope checks and before opening a device tunnel.

Native device discovery is `GET /api/controller/devices`. Screen and camera
signaling use `GET /api/controller/devices/{id}/signal` with the optional
canonical `media=camera` query. A controller signs the WebSocket upgrade exactly
like any other GET request. The relay requires `screen.view` or `camera`, then
places the authenticated controller's sorted scopes in the protected
relay-to-device open message. It refuses native signaling to a daemon that does
not advertise `controller.scoped_sessions`; silently trusting an older daemon
would expose every P2P DataChannel regardless of scope.

The device creates `control` only for `device.control`, `audio` and `room-mic`
only for `audio.listen`, and `mic-in` only for `microphone.talk`. Scoped native
sessions do not yet receive the legacy `files` DataChannel: its device reply
path has process-global transfer ownership and cannot safely isolate concurrent
controllers. `files.read` and `files.write` are reserved for the session-owned
native file protocol increment; until then they fail closed. Missing, malformed,
unknown, or self-asserted scopes grant nothing. Admin-browser and local-LAN
sessions omit the scopes field and preserve their existing full-access behavior.

Refresh uses the same proof format with the refresh token id. On success every
previous access token is removed before a new access token is returned together
with the unchanged refresh token and renewed inactivity expiry. Applications
serialize refresh per relay profile. If a response is lost, the application may
retry the same refresh credential with a fresh timestamp, nonce, and signature;
the exact original request remains a rejected nonce replay.

## Lifecycle

Administrators can list, rename, revoke, and delete controllers independently.
Revoke invalidates all of that controller's tokens and cancels its active native
signaling WebSockets immediately. Future long-lived native tunnel routes must
join the same controller-owned cancellation registry before release. Revoke
does not modify device enrollment, `DeviceSecret`, browser sessions, or another
controller.

Every object follows the same state model: active, revoked, deleted. Revoke is
the security action; delete is bookkeeping and is accepted only for a revoked
controller (`409 controller_active` otherwise), so a live phone can never vanish
in one click. Deleting removes the controller row, its tokens, nonces, and
reported device profile. Audit rows are never deleted by this: each row stores a
snapshot of the actor (admin session browser fingerprint, or controller name) at
write time, so the activity feed stays readable after the object is gone. The
same rule applies to enrollment tokens: only used, expired, or revoked tokens can
be deleted from history (`409 enrollment_active`). Both lists offer a bulk
clear, and `RCTL_RELAY_HISTORY_RETENTION` (default 720h, `0` disables) purges
terminal records automatically.

```text
POST /api/admin/controllers/{id}/delete       revoked only
POST /api/admin/controllers/clear-history     every revoked controller
POST /api/admin/enrollments/{id}/delete       used, expired or revoked only
POST /api/admin/enrollments/clear-history     every terminal token
```

The controller app reports a bounded device profile through a signed request
(`POST /api/controller/me/client`, body `{"client": {...}}`) once after pairing
and again only when the profile's fingerprint changes. The relay keeps a
whitelist of typed keys with size limits (schema and protocol version, install
channel, a list of capability tokens describing what that app build supports,
hardware identifier and marketing name, system name/version/build, app
version/build, bundle id, device name, locale, language, time zone, screen, CPU
count and memory) and drops anything else, so older relays and newer
apps interoperate. Booleans are JSON booleans. The presence heartbeat may carry
`{"telemetry": {...}}` with battery level and state, Low Power Mode, thermal
state, network type plus metered/Low Data flags, the phone's private LAN IP,
memory available to the app; an empty body stays valid. The relay also records
the source IP the controller paired from, its last source IP and its User-Agent.
These are observed addresses, not necessarily public addresses behind a proxy.

Schema 2 acknowledges the accepted contract explicitly. The app only caches a
fingerprint after `accepted_schema_version: 2`; old-relay responses retry with
a five-minute foreground backoff. The profile also includes `protocol_minor`;
`build_revision` is optional and comes from an operator-supplied
`RCTLBuildRevision` Info.plist value, never a guessed revision. Release install
channel is `unknown` unless trustworthy distribution metadata is implemented;
receipt/provisioning-file heuristics are not proof of App Store distribution.

Automatic reporting no longer reads or sends boot uptime or disk capacity/free
space. The manifest declares own-app preferences (CA92.1) and local elapsed
timers (35F9.1), not remote boot-time diagnostics. A future voluntary diagnostic
report requires a separate user-visible review and explicit submission flow.
See [Apple's required-reason API policy](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
This is not an App Store approval claim: audit the final archive and third-party
SDK manifests before submission. Existing stored reports are not retroactively
deleted by this change; new full reports replace them. Backup retention remains
the relay operator's responsibility.

Reports are linked to the persistent controller identity and may contain a
user-assigned name. They are not anonymous. The privacy manifest declares linked
device identity, names, diagnostics and interactions for app functionality,
without advertising tracking. The admin displays last-reported condition and
its age; offline/older-than-90-seconds readings are stale. Zero memory is a value,
not missing data, and a private IP alone does not establish network proximity.

### Transport loss and grants

Each relay transport owns only its routed WebRTC sessions. Resetting that
transport removes its routes and closes those PeerConnections, even if a worker
still retains a reference. LAN and other relay owners are untouched. Late receive
callbacks from a replaced transport are ignored by connection generation.
If relay delivery of a signaling `close` fails, the server closes that exact
device WebSocket so the daemon fails closed instead of leaving P2P running.

This is not a zero-latency revocation guarantee across a partition. A half-open
transport is detected by the existing device supervisor (40-second inactivity
threshold plus scheduling delay). There is no per-session renewable authorization
lease yet. Before adding a permissions editor, qualify lost-link teardown on
rootful and rootless and add a versioned grant/revision protocol if bounded
revocation independent of transport health is required. Never implement scope
editing as only a database or UI change. The native app refreshes `/me` and closes
an established session on changed grants; pairing identity and credentials remain.

Verification for this increment (2026-09-11): relay `go test ./...` and targeted
`-race` tests passed; native `make test` passed; the separate real-libdatachannel
ownership test passed, including retained PeerConnection references. Swift
RctlClient tests and iOS app lifecycle tests passed. Both rootful and rootless
packages compiled. The rootful build was installed through the watchdog deploy
path and passed real LAN video, diagnostics and suspend/resume qualification.
Rootless installation of this increment, active P2P revocation under a network
partition, and physical controller-app validation remain unqualified. Do not
infer those results from package compilation or the host teardown test.

Deliberately not collected: IMEI, serial number, UDID, advertising or vendor
identifiers, Wi-Fi SSID/BSSID, contacts or accounts. Apple does not expose the
first group to third-party apps at all, SSID needs location permission, and none
of them helps operate a controller: the relay-issued controller id and the P-256
key fingerprint already are its stable identity. `device_name` is the bare
model word on iOS 16+ unless the app carries Apple's user-assigned-device-name
entitlement, so the app defaults a new controller's name to the marketing model
name and the admin can rename it.

The admin page deliberately separates device enrollment from controller
pairing. Device enrollment creates a personalized iPad package or token;
controller pairing authorizes an iOS or Android client. The default Everyday
controller preset excludes terminal, update, and destructive-system scopes;
Owner access must be selected explicitly.

Bounded audit events record controller id, operation, scope, device id, result,
and network metadata, never token material, signatures, nonces, public keys, QR
payloads, request bodies, terminal bytes, paths, clipboard data, or media.

The app stores private keys and refresh credentials in Keychain/Keystore. Access
tokens are memory-only when practical. Deleting a relay profile deletes its key
and tokens locally; losing a phone is recovered by revoking that controller from
the relay admin page and pairing a replacement.

The iOS implementation lives in `mobile/ios/Modules/RctlClient`. It rejects
non-HTTPS production origins and protocol-major mismatches before creating a
key, exports the CryptoKit P-256 public key as RFC 5480 SPKI, signs the exact
messages documented above, and stores only the refresh credential and either a
wrapped Secure Enclave key reference or software fallback key in the
non-migrating iOS Data Protection Keychain.
The access token remains an in-memory session concern. Refresh calls must be
serialized by the application session coordinator; retry policy remains above
the low-level API.

`LiveRelayInteropTests` is an opt-in end-to-end contract check. Against a local
ephemeral Go relay it performs pairing, a signed identity request, refresh-token
recovery, a second signed request, and administrative revocation.
