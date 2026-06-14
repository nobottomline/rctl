# Transport Architecture Notes

This document is the handoff note for the next engineer working on internet
remote control.

## Current State

Local LAN mode works well enough:

- `rctld` serves `web/index.html`.
- Browser fetches `/stream`.
- `rctld` sends chunked HTTP frames containing H.264 Access Units and small
  control/audio frames.
- Browser decodes H.264 with WebCodecs.
- Input, keys, files, device info, and terminal are local HTTP/WebSocket calls to
  `rctld`.

Internet relay mode is functional but not a good video transport:

- The Go relay handles admin auth, enrollment, device approval, and sessions.
- Device control/API calls go through `/proxy/devices/{id}/...`.
- Video uses `/stream/devices/{id}/stream`.
- Video frames currently travel iPad -> relay -> browser over reliable TCP-based
  WebSocket/HTTP paths.
- Terminal has its own relay tunnel at `/term/devices/{id}` and works.
- Video stream was moved off the main device control WebSocket into a binary
  stream channel, which prevents video from blocking terminal/control as badly,
  but it does not solve video latency.

The remaining problem is architectural: reliable ordered TCP is the wrong
default for realtime screen video over the public internet.

## Why The Current Relay Video Freezes

Remote desktop video must prefer the newest useful frame over complete delivery
of every old frame. The current relay path does the opposite:

- TCP preserves order.
- If one video chunk is delayed, all later chunks wait behind it.
- H.264 delta frames depend on earlier frames, so stale queues become visible as
  frozen video.
- WebCodecs cannot recover low latency if the transport keeps feeding old frames.
- Backpressure fixes can stop control starvation, but they cannot make reliable
  ordered video behave like a realtime transport.

Symptoms seen in practice:

- Local browser on the same Wi-Fi remains responsive.
- Relay control and terminal can work after separating channels.
- Relay video shows the first few frames, then stalls or lags seconds behind.

This means the encoder and local WebCodecs pipeline are not the primary problem.
The internet video transport is.

## Target Transport

Keep the Go relay for control-plane responsibilities:

- admin login/session management;
- enrollment and approval;
- device presence;
- signaling exchange;
- fallback HTTP/terminal tunnels;
- future TURN credential issuance if needed.

Move realtime media/control to WebRTC DataChannels:

- Browser side: native `RTCPeerConnection`.
- iPad side: `libdatachannel` inside `rctld`.
- Signaling: Go relay stores and forwards offers, answers, and ICE candidates.
- NAT traversal: STUN first, TURN via `coturn` for networks where direct UDP
  fails.

Do not use full `libwebrtc` unless `libdatachannel` proves impossible on the
jailbroken iOS target. `libwebrtc` is far larger, harder to cross-compile, and
contains a media stack we do not need because rctl already owns H.264 encode and
WebCodecs decode.

## Channel Design

Use multiple DataChannels:

```text
video
  ordered: false
  maxRetransmits: 0
  payload: current rctl framed H.264 Access Units
  behavior: drop stale delta frames; recover on the next keyframe

control
  ordered: true
  reliable
  payload: input/key/config commands or a compact binary equivalent

terminal
  ordered: true
  reliable
  payload: existing terminal packets

files/api
  keep current relay HTTP tunnel initially
  move later only if needed
```

The important part is `video` being unordered/unreliable. Lost video packets are
acceptable. Delayed old video packets are harmful.

## Browser Decode Rules

The browser should keep using WebCodecs, but it must become explicitly
latency-oriented:

- Track `VideoDecoder.decodeQueueSize`.
- Drop delta frames when the queue is too deep.
- If a keyframe is needed, drop all video until the next keyframe.
- Request or force periodic keyframes from the device.
- Keep a visible transport status: connected, reconnecting, waiting keyframe,
  high latency, relay fallback.

## iPad / rctld Rules

`rctld` should continue to own local capture and H.264 encode.

For the WebRTC path it should:

- connect to relay for auth/presence as today;
- receive a signaling command or poll signaling state;
- create a `libdatachannel` PeerConnection;
- send encoded Access Units on the `video` DataChannel;
- accept control input on the `control` DataChannel;
- keep local LAN HTTP mode unchanged.

The `.deb` installed on a device must continue to work locally even when relay
configuration exists or the relay is offline.

## Fallback Strategy

Do not delete the current relay video path immediately.

Keep this priority:

1. Local LAN HTTP/WebCodecs path.
2. WebRTC/libdatachannel internet path.
3. Current relay HTTP/WebSocket stream as fallback/debug only.

The fallback is useful for smoke tests, HTTP-only environments, and diagnosing
signaling failures, but it should not be treated as the production internet
video path.

## Implementation Plan

Phase 1: signaling skeleton

- Add relay APIs for offer/answer/candidate exchange.
- Add browser-side `RTCPeerConnection` behind a feature flag.
- Add smoke tests for signaling state only.

Phase 2: libdatachannel spike

- Build a minimal `libdatachannel` executable on macOS/Linux.
- Verify browser <-> native DataChannel with STUN disabled on localhost.
- Add a small binary protocol test using synthetic H.264-like frames.

Phase 3: iOS build

- Cross-compile `libdatachannel` and required dependencies for iOS arm64.
- Link into `rctld`, not SpringBoard.
- Keep arm64-only daemon constraints in mind for iOS 14.4.

Phase 4: video channel

- Send current rctl video frame format over unreliable unordered DataChannel.
- Add keyframe recovery and frame dropping in the browser.
- Keep the old `/stream` endpoint behind fallback mode.

Phase 5: TURN

- Document `coturn` deployment.
- Make relay admin show whether a connection is direct, STUN, TURN, or fallback.
- Add health checks for TURN reachability.

## Security Notes

- Signaling must require an authenticated admin/browser session and an approved
  online device.
- Device secrets stay device-only; relay stores only hashes.
- TURN credentials should be short-lived if generated dynamically.
- The public release `.deb` must remain LAN-only and must not embed maintainer
  infrastructure, domains, IP addresses, tokens, or secrets.

## Decision

The current relay video transport is a compatibility fallback, not the final
internet architecture.

The next serious engineering step for internet video is WebRTC DataChannels via
`libdatachannel`, with the Go relay acting as auth/signaling/TURN coordination.
