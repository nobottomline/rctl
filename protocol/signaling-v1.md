# Controller Signaling v1

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
