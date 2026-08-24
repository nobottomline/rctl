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

Claim returns an access token valid for ten minutes and a refresh token valid
for thirty days. Tokens are independent high-entropy opaque values stored only
as keyed hashes. Refresh rotates both tokens atomically; replaying a replaced
refresh token fails and may revoke its token family.

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

Refresh uses the same proof format with the refresh token id. On success the old
refresh token and every access token from its generation are revoked before the
new pair is returned. Applications serialize refresh per relay profile and
discard an ambiguous response rather than retrying an old token concurrently.

## Lifecycle

Administrators can list, rename, and revoke controllers independently. Revoke
invalidates all of that controller's tokens and closes its active HTTP streams,
terminal and signaling WebSockets. It does not modify device enrollment,
`DeviceSecret`, browser sessions, or another controller.

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
