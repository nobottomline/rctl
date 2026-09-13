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
  `rctld`: screen and camera each use a dedicated H.264 RTP PeerConnection;
  the screen connection also carries DataChannels for input, audio, and bounded
  file operations.

For video, the reliable relay stream remains a compatibility/debug fallback;
the same bounded tunnel is the production path for large downloads:

- Device control/API calls can go through `/proxy/devices/{id}/...`.
- Fallback video can use `/stream/devices/{id}/stream`.
- Large downloads use `/stream/devices/{id}/v1/pull_stream?...` so each hop
  remains bounded and the browser download manager owns the destination file.
- Terminal has its own relay tunnel at `/term/devices/{id}`.

Reliable ordered TCP remains the wrong default for realtime screen video over
the public internet, so the relay stream should not be treated as the preferred
remote-desktop transport.

## Why The Legacy Relay Stream Freezes

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
- Control/audio/bounded file operations: reliable DataChannels.
- Large downloads: bounded HTTP stream, tunneled through the relay when remote.

The pinned iOS build uses libjuice (`USE_NICE=0`). Its libdatachannel ICE backend
accepts TURN/UDP but explicitly skips TURN/TCP and TURN/TLS servers. Browser-side
TURN/TCP support is a separate capability: a successful browser allocation does
not prove the iPad can reach TURN over TCP, or that browser/device ICE connects.
Do not advertise an all-TCP fallback for UDP-blocked device networks. The
September 13 clean-host device test exposed a separate libjuice parsing defect:
a present `ICE-CONTROLLED` attribute with a zero tie-breaker was treated as
missing and rejected with `400`. The pinned dependency now tracks role-attribute
presence independently; see `third_party/webrtc/README.md` for the patch and
authenticated regression tests. Physical RC4 tests established browser TURN/TCP
and both-peer relay connectivity, including a 90-second ordinary-UI session.
An unlocked session also passed visual screen/input checks. A later black-frame
recurrence coincided with the physical display switching off. Exact-candidate
tests subsequently found a distinct decoder stall on forced-TURN paths;
see `ROOTLESS-RELEASE.md` for current evidence. A TCP-connected browser can
communicate with a UDP-connected device through TURN, but this is not an
all-TCP path.

Do not use full `libwebrtc` unless `libdatachannel` proves impossible on the
jailbroken iOS target. `libwebrtc` is far larger, harder to cross-compile, and
contains a media stack we do not need because rctl already owns H.264 encode and
WebCodecs decode.

## Channel Design

The current design keeps one media SSRC per PeerConnection. The iOS
libsrtp/mbedtls build previously dropped all RTP when a second media SSRC was
added to the same connection, so camera is a second signaling session rather
than a second m-line on the screen connection:

```text
video
  RTP H.264 media track
  payload: VideoToolbox Annex-B access units packetized by libdatachannel
  recovery: NACK + debounced PLI -> forced keyframe

camera
  separate PeerConnection selected by ?media=camera
  RTP H.264 from the foreground rctlapp VideoToolbox encoder
  recovery: independent NACK + PLI

control
  ordered: true
  reliable
  payload: touch/key commands

audio
  ordered: true
  reliable
  payload: Opus frames on independent app-audio, room-mic, and mic-in channels
  direction: device->browser for listening; browser->device for Talk

files
  ordered: true
  reliable
  payload: JSON control + binary chunks
```

The terminal still uses its dedicated WebSocket tunnel. General REST calls still
use the authenticated HTTP tunnel.

### Video Packet Budget

Screen and camera use a maximum H.264 fragment of 1100 bytes. The pinned
packetizer's default fragment size does not reserve space for all of our
playout-delay RTP extension, SRTP authentication, and TURN encapsulation.
With those additions it can exceed a 1280-byte IPv6 packet, even though the
fragment itself fits the upstream default. Reserve 20 bytes for the current
RTP header/extension, 16 for SRTP, 64 for a TURN indication including padding,
and 48 for IPv6/UDP: the resulting bound is 1248 bytes. ChannelData uses less
overhead than the indication allowance. This avoids depending on fragmentation
at that MTU; it does not discover or guarantee every VPN's effective path MTU.

`bash scripts/test-webrtc-ownership.sh` exercises the production packetizer for
screen and camera using a synthetic large IDR. It checks every emitted packet's
wire budget, the final marker, and preservation of NAL payload bytes. The test
fails with the former default and passes with the explicit fragment size.
The draft workflow runs it before building either public package lane.
Actual TURN performance, camera playback, and device compatibility still require
physical testing; passing this test alone does not close the release gate.

### Remote Screen Pacing

Remote screen sessions wrap the existing libdatachannel H.264, sender-report,
NACK and PLI chain in a session-owned `VideoPacer`. LAN screen and camera
sessions retain their previous send path. The daemon feeds the pacer the same
bitrate it requests from the screen encoder, including profile/adaptation
changes; this is not a new bandwidth estimator or congestion controller.

The queue admits complete access units and is bounded to 512 KiB, 64 frames,
and 500 ms residence. It schedules packets in 2 ms ticks at 1.5 times the encoder
bitrate, accruing credit from actual elapsed time rather than assuming the
scheduler meets every deadline. Catch-up is capped at 10 ms of traffic. On Apple
platforms the session worker requests user-initiated QoS; it still waits when
idle and is destroyed with the session. Overflow,
expiry or a send exception discards the remaining queue and dependent delta
frames until a fresh keyframe arrives, requesting recovery through the existing
debounced PLI path. An already in-flight packet cannot be recalled. Session
retirement stops admission and clears queued packets; destruction joins the
worker. Idle workers wait rather than polling, and no power assertion is added.

The upstream packet-level pacer was not used because its packet eviction does
not retire the rest of a damaged frame and dependent frames. RTP serialization
and repair remain upstream-owned: RTCP and NACK retransmissions still bypass
the original-media queue. Thus the rate is a pacing target, not a total wire
bandwidth limit. Loss, available bandwidth, and larger-than-bound keyframes
can still prevent useful playback and require physical qualification.

Remote screen SDP no longer constrains receiver playout to 0-60 ms, and the web
client no longer forces its remote receiver delay hint to zero. This lets the
browser adapt to repair RTT; it does not guarantee low latency. The existing
LAN floor and camera policy are unchanged. Test both the new device package and
new web client: an old relay-served client can still force the previous hint.

The native ownership suite covers spacing, overflow/expiry recovery, send
failure, stop, and the real asynchronous RTP packet budget. Runtime acceptance
remains tracked separately in `ROOTLESS-RELEASE.md`.

## Browser Decode Rules

WebRTC H.264 is decoded natively by the browser's video pipeline. WebCodecs is
kept for the HTTP `/stream` compatibility path, where it must remain explicitly
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
- exposes audio and bounded file operations on separate DataChannels;
- publishes versioned orientation state on the `state` DataChannel;
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
RTP media track, control/audio/bounded file operations over DataChannels, and
the Go relay as the auth/signaling/TURN and large-download streaming plane.
