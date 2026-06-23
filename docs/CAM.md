# Camera and Microphone Architecture Notes

Goal: add live front/back camera streaming and microphone streaming without
mixing them with the existing screen and system-playback-audio paths.

## Existing media tracks

Current working tracks:

| Track | Source process | Owner | Notes |
|---|---|---|---|
| `screen` | SpringBoard | `springboard/` | H.264 from the display framebuffer |
| `sys_audio` | mediaserverd | `audio/` | PCM copied from supported playback paths, for YouTube/TikTok/app output |
| `cam_still` | foreground app | `cap/` | one-shot front/back JPEG capture |

Target tracks:

| Track | Source process | Owner | Notes |
|---|---|---|---|
| `cam` | foreground app | future `cam/` or upgraded `cap/` | live front/back camera video |
| `mic` | foreground app | future `cam/` or upgraded `cap/` | microphone input, separate from `sys_audio` |

Do not merge `sys_audio` and `mic`. They are different products:

- `sys_audio`: what the iPad is playing.
- `mic`: what the iPad hears in the room.

## Known iOS constraint

Camera access is validated by iOS/mediaserverd against the foreground app. Prior
daemon/SpringBoard camera attempts reached authorization but were rejected at
hardware client validation. The current still-photo path works because `rctlapp`
is injected into every UIKit app and only the active foreground app performs the
capture.

This means the first professional live-camera design should not start by
reverse-engineering mediaserverd. The lower-risk path is to extend the existing
foreground-app capture model.

## Recommended model: roaming foreground capture

`rctld` owns desired state. The active foreground app owns actual capture.

```text
browser
  -> /v1/cam?on=1&pos=front
  -> /v1/mic?on=1

rctld
  desired cam/mic state
  current owner app pid/bundle
  generation/session id
  ingest sockets

foreground app agent
  starts capture when active and desired state is on
  stops capture when resigning/backgrounding
  new foreground app resumes capture automatically
```

The goal is not to keep one `AVCaptureSession` alive across app switches. iOS may
stop or invalidate the old session when the app leaves foreground. The product
behavior should be:

- app A active: camera stream is live from app A;
- app switch starts: stream status becomes `reconnecting`;
- app B becomes active: app B sees desired state and starts capture;
- SpringBoard/home screen: status becomes `waiting_for_app`.

This is the most honest, robust model for current iOS constraints.

## Probe phase

Before product UI, run diagnostic probes on the current iPad/iOS 14.4:

1. **Live video viability**
   - Start `AVCaptureSession` inside the active app.
   - Use `AVCaptureVideoDataOutput`.
   - Count frames for 10, 30, and 120 seconds.
   - Verify no host app crash.

2. **Front/back switching**
   - Start front camera.
   - Stop cleanly.
   - Start back camera.
   - Verify no leaked sessions or camera lock.

3. **App lifecycle**
   - Log `UIApplicationDidBecomeActiveNotification`.
   - Log `UIApplicationWillResignActiveNotification`.
   - Start stream, switch app, observe whether frames stop, callbacks continue,
     or mediaserverd invalidates the session.

4. **Roaming owner**
   - Keep desired state in `rctld`.
   - Active app asks `rctld` whether camera/mic should be running.
   - New foreground app starts capture automatically.

5. **Microphone viability**
   - Add `AVCaptureAudioDataOutput`.
   - Verify `kTCCServiceMicrophone` handling.
   - Stream PCM as a separate `mic` track.
   - Verify it does not affect `sys_audio`.

6. **Performance**
   - Test 5/10/15/30 fps.
   - Measure frame drops, CPU, battery, and thermal behavior.
   - Prefer stable lower fps over unstable high fps.

## Transport choices

MVP options:

| Option | Pros | Cons | Recommendation |
|---|---|---|---|
| JPEG/MJPEG frames | simple, debuggable, easy browser rendering | bandwidth heavy, CPU heavy | good first probe |
| H.264 inside app | efficient, aligns with screen stream | more code in injected app | product target |
| raw frames to daemon | daemon centralizes encode | huge bandwidth over loopback, costly copies | avoid unless needed |
| WebSocket ingest | easy session framing | more protocol work | good for browser-facing streams |
| TCP ingest | simple from sandboxed apps | custom framing needed | good app-agent to daemon path |

Recommended order:

1. JPEG frame probe to prove live capture and app-switch behavior.
2. H.264 app-side encoding once the lifecycle is proven.
3. Later WebRTC tracks for internet/low-latency media.

## Proposed module names

Keep names short:

- `cap/`: current still-camera agent.
- `cam/`: future live camera/mic foreground agent, or rename/upgrade `cap/`
  once still and live capture share one module.
- `audio/`: system playback audio from mediaserverd.
- `term/`: terminal concept/docs, code currently under `core/net/Term.*`.

Endpoint names:

```text
/v1/cam?on=1&pos=front
/v1/cam?on=0
/v1/cam_status
/v1/mic?on=1
/v1/mic?on=0
/v1/mic_status
```

Ingest names:

```text
/v1/cam_frame      diagnostic JPEG frame upload
127.0.0.1:8081     future app-agent media ingest
```

## Status model

Camera and mic status should be explicit:

```text
off
starting
live
reconnecting
waiting_for_app
unavailable
error
```

The browser should show these states instead of pretending the camera is always
continuous across app switches.

## Safety rules

- Never run camera/mic capture in SpringBoard.
- Do not block an app's main thread with frame encoding or socket writes.
- Stop capture on app resign/background.
- Use bounded queues and drop frames under backpressure.
- Keep camera/mic disabled by default.
- Keep `sys_audio`, `mic`, and `cam` as separate tracks in UI and protocol.
- Log lifecycle/status, not private media contents.

## First implementation milestones

1. **Diagnostic live camera probe**
   - Extend the current foreground-app agent with a diagnostic video-output path.
   - Send low-rate JPEG frames to `rctld`.
   - Add frame count/status logs.

2. **Roaming camera session**
   - Add daemon desired state.
   - Active apps query/pick up desired state.
   - Browser shows live/reconnecting/waiting status.

3. **Microphone track**
   - Add `AVCaptureAudioDataOutput` in the same foreground-agent lifecycle.
   - Send PCM as a separate track.
   - Verify app switching and TCC behavior.

Only after these are stable should the camera path move to H.264/WebRTC.
