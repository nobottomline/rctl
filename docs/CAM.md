# Live Camera Architecture

`rctl` streams the front or rear camera from the active foreground app, sends
H.264 to `rctld` over a bounded loopback ingest, and publishes it as a dedicated
WebRTC RTP session. The daemon can record the same encoded stream directly to an
MPEG-TS file without a second encoder.

The capture, relay and recording paths have been validated on the target iOS
14.4 arm64e device. Long-duration, rotation and app-roaming soak tests remain
release gates; see the validation matrix below.

## Media ownership

| Track | Capture process | Transport | Notes |
|---|---|---|---|
| `screen` | SpringBoard (`rctlsbcap`) | H.264 RTP | display and remote input session |
| `camera` | foreground app (`rctlappmedia`) | separate H.264 RTP PeerConnection | front or rear camera |
| `sys_audio` | mediaserverd (`rctlaudio`) | Opus DataChannel | device playback mix |
| `room-mic` | `rctld` RemoteIO | Opus DataChannel | experimental; currently unsafe |

iOS/mediaserverd validates camera access against the foreground application.
Camera capture from `rctld` or SpringBoard is rejected even with authorization,
so the small `rctlapp` loader is injected into UIKit applications and only loads
`rctlappmedia` in non-SpringBoard processes. The heavy camera/virtual-mic payload
never enters SpringBoard.

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
  -> dlopen rctlappmedia (ordinary UIKit apps only)
  AVCaptureVideoDataOutput (640x480, default 10fps)
  -> VideoToolbox H.264 (bounded three-frame network queue)
  -> Annex-B access units over loopback TCP
```

The camera uses a separate PeerConnection, not a second track on the screen
PeerConnection. The current iOS libdatachannel/libsrtp build has previously
dropped all media after adding a second SRTP SSRC. One H.264 media SSRC per
PeerConnection preserves native RTP fragmentation, NACK, PLI and browser decode
without reintroducing that failure.

### Foreground payload boundary

`rctlapp.dylib` remains a small MobileSubstrate-filtered loader because the UIKit
bundle filter also matches SpringBoard on this device. Live camera and virtual
microphone code is linked into `rctlappmedia.dylib`, which has no substrate filter
plist and is opened explicitly only after the loader rejects SpringBoard. This
prevents C++/VideoToolbox initialization from destabilizing SpringBoard or
blocking later Substitute payloads.

On iOS 14 arm64e, late `dlopen` of a dylib containing static Objective-C class
metadata triggered pointer-authentication failure in dyld. The camera frame
delegate is therefore registered at runtime with `objc_allocateClassPair` after
the payload is loaded. Both payloads are fat arm64/arm64e binaries.

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

A new recording ignores delta frames until the first keyframe and requests an
immediate IDR from the foreground encoder. The file therefore starts with the
SPS/PPS/IDR needed by a standalone decoder instead of inheriting the tail of an
already-running GOP.

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

Current physical baseline (iPadOS 14.4, arm64e):

| Scenario | Result |
|---|---|
| Local rear and front live H.264 | Pass; frames advance and front image is non-empty |
| Hot rear/front switch | Pass; owner remains the foreground app |
| Relay camera PeerConnection | Pass; dedicated track is unmuted and frames advance |
| Camera close and screen recovery | Pass; screen track resumes without reconnecting control |
| On-device MPEG-TS recording | Pass; starts on IDR and decodes cleanly with FFmpeg |
| 10/30 minute, rotation and multi-app soak | Pending release qualification |
