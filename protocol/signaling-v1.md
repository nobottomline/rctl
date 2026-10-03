# Controller Signaling v1

This contract also defines the separately negotiated browser guest mode below.

Browser-admin relay endpoints are `/signal/devices/{id}` for screen and
`/signal/devices/{id}?media=camera` for camera. Native controllers use the
proof-authenticated `/api/controller/devices/{id}/signal` endpoint with the same
optional `media=camera` query. Direct LAN uses `/ws/signal` and the same
controller-facing envelopes. Messages match
`schemas/signaling.schema.json` and stay below `signaling_json_bytes` in
`limits.json`.

```text
controller opens WebSocket
  relay: relay -> ready(ICE servers)
  device -> offer
  device/controller <-> candidate*  (candidates may precede remote SDP)
  controller -> answer
  PeerConnection connecting -> connected
  WebSocket close / failure -> generation teardown
```

The device is the offerer. A controller queues remote candidates received before
setting the remote offer. `ready` is optional in direct-LAN mode. Screen and
camera use separate WebSockets and PeerConnections. A reconnect creates a new
generation; callbacks and candidates from an older generation cannot mutate the
new session.

The relay treats SDP and ICE as opaque authenticated payloads. Both endpoints
validate kind, shape, and size before handing data to WebRTC. Unknown kinds and
malformed messages are rejected; they never trigger implicit renegotiation.

Native signaling requires `screen.view` or `camera` for the selected media role.
The relay forwards the controller's complete sorted scope set only in its
authenticated device-side `open` envelope. A daemon advertising
`controller.scoped_sessions` fails closed and creates only the DataChannels
authorized by that set. Browser-admin and direct-LAN opens omit scopes and retain
their existing full-trust behavior. The controller never supplies its own scopes.
The legacy process-global `files` transfer channel is deliberately omitted from
scoped native sessions until file transfer ownership becomes per-session.

## Controller Authorization Lease v1

New relays require both `controller.scoped_sessions` and
`controller.authorization_lease_v1` before accepting native signaling. An older
device returns HTTP 409 `device_authorization_lease_not_supported`; admin-browser
and LAN access remain independent. Update devices before updating the relay.
New devices accept legacy scoped opens without a revision from old relays for
rolling upgrades; those old relays have no permissions editor or bounded lease
guarantee. A revision-bearing open never falls back to legacy behavior.

Only the authenticated relay-device WebSocket carries these envelopes. Native
controllers cannot send them through their signaling socket or DataChannels:

```json
{"type":"webrtc_signal","id":"sig_example","kind":"open","payload":{"role":"screen","ice":[],"scopes":["screen.view"],"authorization_revision":2}}
{"type":"webrtc_signal","id":"sig_example","kind":"authorization_challenge","payload":{"authorization_revision":2,"nonce":"<64 lowercase hex characters>"}}
{"type":"webrtc_signal","id":"sig_example","kind":"authorization_renew","payload":{"authorization_revision":2,"nonce":"<same nonce>"}}
```

The device starts no PeerConnection before the first valid renewal. It generates
a random 32-byte nonce and keeps at most one outstanding challenge per session.
The relay checks the controller's **current** active status and revision in the
database for each challenge, and only echoes a matching grant. No challenge is
forwarded to the controller. Role, scopes and revision never mutate in place.

The lease is 20 seconds from device-local challenge issuance, using
`mach_continuous_time` (including sleep). Renewal is requested after five seconds;
the bridge watchdog runs every second. A response is accepted only before both
the previous lease and challenge deadlines. Duplicate, wrong-revision, expired
and retired-session replies cannot renew access. Pending and active leases share
a 512-entry cap; live records are never evicted to make room.

On expiry, the device disables input and tears down that PeerConnection and its
media channels. Normal teardown is within one watchdog tick of expiry, subject
to OS scheduling; this is not a hard realtime guarantee. Already delivered media
and already dispatched device actions cannot be recalled. A delayed response
does not restart a full TTL from arrival. Relay loss/replacement retires all its
pending and active leases, without touching LAN or another relay's ownership.

Permission changes cancel existing controller signaling with WebSocket 1008 and
close the device sessions. If delivery fails, the lease bounds continued P2P
access without trusting the phone to disconnect. The iOS client refreshes `/me`,
keeps its pairing, stops automatic retry on 1008, and requires a new session in
View. General network failures may retry with fresh authorization, also in View.

## Browser Guest Authorization v1

Guests connect to `/api/guest/signal` using their own host-only browser cookie
and the configured HTTPS Origin. The relay resolves the device from that session;
the guest supplies no device identifier, scopes or authorization envelope.
Only devices advertising `guest.scoped_sessions_v1` are eligible. Guest mode
currently permits the screen role only and requires `screen.view`.

The protected relay-device `open` has `access_mode: "guest-v1"`, a positive
`authorization_revision`, the explicit `permissions` from
`guest-permissions.json`, and an explicit Boolean `allow_direct`. It omits native
`scopes`. Missing/unknown permissions, malformed guest policy or an unsupported
role reject the open, without falling through to full-trust mode. Session identity
is the relay-created signal ID; it is never a guest-supplied input owner.

The challenge/renewal exchange remains on the protected relay-device transport.
The relay checks the current session, grant revision, approved device and absolute
expiry on every challenge. A guest renewal includes `remaining_ms`, the lesser of
20,000 and remaining absolute grant lifetime. The device starts that budget at
local challenge issuance, never reply arrival. Missing/nonpositive/oversized
budgets fail closed, and expired or retired leases cannot be revived. The
`allow_direct: false` default configures relay-only ICE on both device and browser;
absence of configured TURN rejects creation/claim. Explicit direct grants retain
normal ICE. This configuration still needs SDP/candidate qualification before
claiming address privacy.

The device creates a video track and state channel for view-only. A `control`
channel exists only when an input permission is present; each message rechecks
lease, ownership, rate and the specific permission. Keyboard page 7 does not grant
consumer/system HID access. Home, lock, volume and system panels have independent
generated permissions. Guests receive no pointer, files, audio, Talk or camera
channels. Native v1 mappings and owner/LAN opens are unchanged.

Revoke, end and real rights changes retire all old guest generations. The relay
does not wait for a browser close handshake. It sends device `close` and awaits
device `closed` (with null/absent payload), emitted only after lease retirement,
media send draining and, for interactive sessions, acknowledged SpringBoard
input cleanup. Failed cleanup sends `close`, not `closed`; repeated close must
retry the pending cleanup fence. The administrative result reports
`disconnect_confirmed` separately from persisted authorization denial. Device
transport failure uses the bounded lease fallback and cannot claim instant
cross-partition revocation. Guest browser teardown clears video/canvas, cancels
pending input and requires manual reconnect after an authorization change.
