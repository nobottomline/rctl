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
DER as unpadded base64url together with platform, name, pairing secret, and a
DER-encoded ECDSA/SHA-256 proof. The signed bytes are UTF-8:

```text
rctl-pair-v1\n
<pairing-id>\n
<pairing-secret>\n
<controller-name>\n
<platform>\n
<base64url-sha256-public-key>
```

Names are trimmed before signing. Platform is `ios` or `android`. The relay
validates the public key, signature, secret, origin-owned pairing record,
expiry, and unused state in one database transaction. At most one concurrent
claim succeeds. Pairing secrets are stored as keyed hashes and are unrecoverable
after the create response.

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

Administrators can list, rename, and revoke controllers independently. Revoke
invalidates all of that controller's tokens and cancels its active native
signaling WebSockets immediately. Future long-lived native tunnel routes must
join the same controller-owned cancellation registry before release. Revoke
does not modify device enrollment, `DeviceSecret`, browser sessions, or another
controller.

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
