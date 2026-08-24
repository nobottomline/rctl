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
