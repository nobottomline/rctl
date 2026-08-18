# Live Camera Architecture

`rctl` streams the front or rear camera from the active foreground app, sends
H.264 to `rctld` over a bounded loopback ingest, and publishes it as a dedicated
WebRTC RTP session. The daemon can record the same encoded stream directly to an
MPEG-TS file without a second encoder.

Source and package builds are complete. Physical iOS 14.4 validation is still
required before this feature is release-qualified.

## Media ownership

| Track | Capture process | Transport | Notes |
|---|---|---|---|
| `screen` | SpringBoard (`rctlsbcap`) | H.264 RTP | display and remote input session |
| `camera` | foreground app (`rctlapp`) | separate H.264 RTP PeerConnection | front or rear camera |
| `sys_audio` | mediaserverd (`rctlaudio`) | Opus DataChannel | device playback mix |
| `room-mic` | `rctld` RemoteIO | Opus DataChannel | experimental; currently unsafe |

iOS/mediaserverd validates camera access against the foreground application.
Camera capture from `rctld` or SpringBoard is rejected even with authorization,
so `rctlapp` is injected into UIKit applications and only acts while its host is
active. SpringBoard is explicitly excluded.

## Data flow

```text
browser
  |  /v1/cam_live desired state + 30s lease
  |  camera signaling WebSocket (?media=camera)
  v
rctld
  |  desired state, generation, owner and status
  |  127.0.0.1:8081 framed H.264 ingest
  |  optional MPEG-TS writer
  v
foreground rctlapp
  AVCaptureVideoDataOutput (640x480, default 10fps)
  -> VideoToolbox H.264 (bounded three-frame network queue)
  -> Annex-B access units over loopback TCP
```

The camera uses a separate PeerConnection, not a second track on the screen
PeerConnection. The current iOS libdatachannel/libsrtp build has previously
dropped all media after adding a second SRTP SSRC. One H.264 media SSRC per
PeerConnection preserves native RTP fragmentation, NACK, PLI and browser decode
without reintroducing that failure.

## Roaming foreground session

`rctld` owns desired state and increments a generation whenever enabled state,
position or encoding settings change. Every injected app observes the Darwin
sync notification, but only the active foreground app starts capture.

- App A active: App A owns capture and reports its bundle id in the ingest hello.
- App switch: App A stops on `UIApplicationWillResignActiveNotification`.
- App B active: App B reads daemon state and starts the current generation.
- Home screen: no valid owner; status is `waiting_for_app`.
- Orientation change: the owner rebuilds its capture/encoder so dimensions and
  SPS/PPS match the new orientation.
- Daemon restart/loss: agents poll state every five seconds and fail closed.

Only the newest ingest owner epoch is accepted. Late frames from a resigning app
are discarded. Payloads are capped at 2 MiB.

## Screen coexistence

The target A12 device showed camera/mediaserverd work starving the screen
VideoToolbox session. While live camera is enabled, `rctld` pauses the expensive
screen capture/encoder but keeps the screen PeerConnection and DataChannels
alive. Input, files and terminal therefore remain connected. Stopping camera
restores screen capture and emits a fresh keyframe through the normal pipeline.

This policy is conservative and should only be relaxed after device thermal,
memory and simultaneous-encoder measurements prove it safe.

## API

```text
GET /v1/cam_live?on=1&pos=back&fps=10&bitrate=1500000
GET /v1/cam_live?on=1&pos=front&fps=10&bitrate=1500000
GET /v1/cam_live?on=0
GET /v1/cam_status?lease=1
GET /v1/cam_record?on=1
GET /v1/cam_record?on=0
GET /v1/cam_record?discard=1
GET /v1/cam_agent_state
```

`cam_agent_state` is the small loopback state document consumed by injected app
agents. `cam_status` reports `off`, `waiting_for_app`, or `live`, plus position,
owner, frame counters and recording metadata.

The browser renews a 30-second camera lease through `cam_status?lease=1`. If a
tab closes, crashes, loses the relay, or is suspended long enough, the daemon
stops camera and recording and resumes the screen. Capture is always off after a
daemon restart.

## Recording

Recording reuses the Annex-B stream received by `rctld`; it does not create
another VideoToolbox session. The daemon writes PAT/PMT, H.264 PES, PTS and PCR
into:

```text
/var/mobile/Library/Caches/com.greatlove.rctl/camera-recording.ts
```

The Console downloads it over the existing `files` DataChannel. MPEG-TS was
chosen because it tolerates app-owner switches, new SPS/PPS and an interrupted
recording without requiring a final MP4 index. A later remux/export layer may
offer MP4 without changing capture or transport.

## Still photos

`/v1/camera?pos=front|back` remains available for full-resolution JPEG stills.
It is rejected with HTTP 409 while live camera is enabled so two foreground
AVCapture sessions cannot race for the device.

## Safety invariants

- Never capture in SpringBoard or `rctld`.
- Never encode or perform socket writes on an app's main thread.
- Bound queued frames and drop under backpressure.
- Stop on app resign, daemon loss, browser lease expiry and explicit disable.
- Keep camera disabled by default.
- Never log or audit frame contents.
- Keep camera RTP independent from screen and audio transports.

## Release validation

Run `make test-camera-recorder` and `make package`, then verify on the target
device:

1. Rear and front video for 2, 10 and 30 minutes.
2. Portrait/landscape rotation and repeated front/rear switching.
3. App A -> App B roaming and Home-screen `waiting_for_app`.
4. Browser close, relay loss and daemon restart fail closed within the lease.
5. Recording across a camera switch; download and inspect with `ffprobe`/VLC.
6. Screen recovery, terminal/files continuity, CPU, memory and thermal state.
