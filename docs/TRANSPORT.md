# Transport Architecture Notes

This document is the handoff note for the next engineer working on internet
remote control.

## Current State

The control app now has two production-maintained transport paths:

- `web/` is the canonical React/Vite control app. `make package` stages the
  single-file `web/dist/index.html` onto the device.
- Local direct-LAN mode first tries WebRTC through rctld's `/ws/signal`; if that
  cannot connect, it falls back to `/stream` + WebCodecs.
- Relay mode uses the Go relay for admin auth, enrollment, approval, device
  presence, signaling, HTTP tunnel, terminal tunnel, and TURN credential minting.
- The low-latency media/control path is WebRTC via libdatachannel inside
  `rctld`: H.264 over an RTP video track, with DataChannels for input, audio,
  and file transfer.

The old reliable relay stream still exists as compatibility/debug fallback:

- Device control/API calls can go through `/proxy/devices/{id}/...`.
- Fallback video can use `/stream/devices/{id}/stream`.
- Terminal has its own relay tunnel at `/term/devices/{id}`.

Reliable ordered TCP remains the wrong default for realtime screen video over
the public internet, so the relay stream should not be treated as the preferred
remote-desktop transport.

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

## Current Target Transport

Keep the Go relay for control-plane responsibilities:

- admin login/session management;
- enrollment and approval;
- device presence;
- signaling exchange;
- fallback HTTP/terminal tunnels;
- TURN credential issuance when configured.

Realtime media/control is WebRTC:

- Browser side: native `RTCPeerConnection`.
- iPad side: `libdatachannel` inside `rctld`.
- Signaling: Go relay stores and forwards offers, answers, and ICE candidates.
- NAT traversal: STUN first, TURN via `coturn` for networks where direct UDP
  fails.
- Video: H.264 RTP media track.
- Control/audio/files: reliable DataChannels.

Do not use full `libwebrtc` unless `libdatachannel` proves impossible on the
jailbroken iOS target. `libwebrtc` is far larger, harder to cross-compile, and
contains a media stack we do not need because rctl already owns H.264 encode and
WebCodecs decode.

## Channel Design

The current design uses one RTP video track plus multiple DataChannels:

```text
video
  RTP H.264 media track
  payload: VideoToolbox Annex-B access units packetized by libdatachannel
  recovery: NACK + debounced PLI -> forced keyframe

control
  ordered: true
  reliable
  payload: touch/key commands

audio
  ordered: true
  reliable
  payload: Opus frames

files
  ordered: true
  reliable
  payload: JSON control + binary chunks
```

The terminal still uses its dedicated WebSocket tunnel. General REST calls still
use the authenticated HTTP tunnel.

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

For the WebRTC path it currently:

- connect to relay for auth/presence as today;
- receives signaling commands from the relay or direct `/ws/signal`;
- creates one `libdatachannel` PeerConnection per signaling session;
- sends encoded access units on the H.264 RTP track;
- accepts control input on the `control` DataChannel;
- exposes audio and file transfer on separate DataChannels;
- keep local LAN HTTP mode unchanged.

The `.deb` installed on a device must continue to work locally even when relay
configuration exists or the relay is offline.

## Fallback Strategy

Do not delete the current relay video path immediately.

Keep this priority:

1. Direct-LAN WebRTC via `/ws/signal`.
2. Relay WebRTC via `/signal/devices/{id}`.
3. HTTP/WebCodecs `/stream` as local/fallback/debug only.

The fallback is useful for smoke tests, HTTP-only environments, and diagnosing
signaling failures, but it should not be treated as the production internet
video path.

## Remaining Work

- Make TURN deployment and health checks easier to operate.
- Show ICE path quality clearly in admin/control diagnostics.
- Keep improving capture restart/keyframe recovery around camera/audio events.
- Keep the old `/stream` endpoint behind fallback mode.


## Security Notes

- Signaling must require an authenticated admin/browser session and an approved
  online device.
- Device secrets stay device-only; relay stores only hashes.
- TURN credentials should be short-lived if generated dynamically.
- The public release `.deb` must remain LAN-only and must not embed maintainer
  infrastructure, domains, IP addresses, tokens, or secrets.

## Decision

The reliable relay video stream is a compatibility fallback, not the final
internet architecture.

The active internet architecture is WebRTC via `libdatachannel`: H.264 over an
RTP media track, control/audio/files over DataChannels, and the Go relay as the
auth/signaling/TURN coordination plane.
