# Controller Signaling v1

Relay endpoint: `/signal/devices/{id}` for screen and
`/signal/devices/{id}?media=camera` for camera. Direct LAN uses `/ws/signal` and
the same controller-facing envelopes. Messages match
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
