# Audio Architecture Notes

Goal: stream the iPad's real playback audio, for example YouTube, TikTok, games,
or call audio, to the controlling browser/client together with the screen stream.

## Current state

- Browser video and touch control work over the LAN HTTP/WebCodecs path.
- Real system playback audio works through the guarded mediaserverd agent in
  `audio/` (`rctlaudio.dylib`).
- The browser `Audio` control enables/disables remote audio capture through
  `/v1/audio_capture?on=1|0|status=1`.
- The browser `iPad` control enables/disables local device output through
  `/v1/audio_output?device=1|0|status=1`. This allows browser-only, iPad-only,
  or both-speakers-on operation.
- The old browser `Tone` button was removed. Synthetic tone generation still
  exists as an internal diagnostic path, not as product UI.

## Runtime components

| Component | Path | Runtime role |
|---|---|---|
| `rctld` | `daemon/` | owns HTTP REST, `/stream`, audio ingest, audio capture lifecycle, and device-output control |
| `rctlaudio` | `audio/` | inactive mediaserverd payload; activated only while real audio capture is requested |
| HTTP stream | `core/net/` | carries H.264 frames plus PCM audio frames to the browser |
| Browser client | `web/` | decodes H.264 via WebCodecs and schedules PCM playback through Web Audio |

`rctlaudio` intentionally stays out of SpringBoard. A bad audio hook must not
respring the UI or break touch/video control.

## Capture lifecycle

`audio/` is built from the top-level package stage, but it is shipped inactive:

- payload dylib: `/usr/local/lib/rctl/audio/rctlaudio.dylib`
- payload plist: `/usr/local/lib/rctl/audio/rctlaudio.plist`

When `/v1/audio_capture?on=1` is called, `rctld`:

1. removes any stale active audio payload or marker, including legacy
   `rctlaudiosource.*` names;
2. copies `rctlaudio.dylib` and `rctlaudio.plist` into
   `/Library/MobileSubstrate/DynamicLibraries`;
3. signs the active dylib with on-device `ldid`;
4. creates `/tmp/rctl-audio-capture`;
5. temporarily idles video capture if a viewer is connected;
6. restarts `mediaserverd`;
7. resumes video and sends a stream reset to the browser.

When `/v1/audio_capture?on=0` is called, or when the last viewer disconnects,
`rctld` removes active files and markers, restarts `mediaserverd` only if needed,
and marks audio capture as inactive.

`postinst` also removes active audio payloads and markers during package install
or upgrade. Audio capture must always start explicitly; it is never left active
across deploys.

## Audio transport

Audio frames use `/stream` frame type `4` with this payload:

```text
[8B BE pts_us]
[4B BE sample_rate]
[1B channels]
[1B bytes_per_sample]
[2B BE frames]
[interleaved S16LE PCM]
```

`rctld` accepts audio packets on:

- `/var/run/rctl-audio.sock` for local daemon-side sources;
- `127.0.0.1:8079` as the mediaserverd-compatible fallback.

On this iPad, mediaserverd cannot connect to `/var/run/rctl-audio.sock`
(`errno=1 Operation not permitted`), but it can connect to `127.0.0.1:8079`.
The product path therefore uses the TCP ingest fallback.

## Capture implementation

`rctlaudio` hooks supported playback paths in mediaserverd:

- `AudioQueueEnqueueBuffer`
- `AudioQueueEnqueueBufferWithParameters`
- `AudioUnitRender`

The hook only copies supported Linear PCM into a bounded in-process queue and
returns to the system render path. It does not perform network I/O on the audio
callback. A worker thread drains the queue, packetizes S16LE frames, and sends
them to `rctld`.

Safety properties:

- capture is opt-in;
- active files are removed on disable, startup cleanup, install, and viewer idle;
- queue length is bounded;
- dropped packets are counted rather than blocking the audio thread;
- the agent has a 180 second watchdog if it is accidentally left active;
- mediaserverd restarts are coordinated with video capture to avoid H.264 stalls.

## Device-output control

`/v1/audio_output` is implemented through the SpringBoard agent because
SpringBoard has the right process context for system volume/output state.

Modes exposed by the browser:

- `Audio` off, `iPad` on: normal iPad playback only.
- `Audio` on, `iPad` on: browser and iPad both play audio.
- `Audio` on, `iPad` off: browser-only remote listening.
- `Audio` off, `iPad` off: muted local playback with no remote audio.

When muting the iPad, the daemon saves the previous volume and restores it when
device output is re-enabled.

## Historical findings kept for reference

The removed `audioprobe/` target was a diagnostic-only mediaserverd probe. It
confirmed the relevant classes and symbols existed on iPad11,3 / iOS 14.4:

- classes: `Core_Audio_Daemon`, `AVAudioSession`, `AVAudioPlayer`,
  `AVAudioRecorder`, `AVCaptureAudioDataOutput`, `AVCaptureFigAudioDevice`,
  `BWAudioSourceNode`, `FigAudioCaptureAudioDataSinkPipeline`, and related
  capture/audio sink classes;
- symbols: `AudioComponentFindNext`, `AudioComponentInstanceNew`,
  `AudioOutputUnitStart`, `AudioOutputUnitStop`, `AudioUnitGetProperty`,
  `AudioUnitSetProperty`, `AudioUnitRender`, `AudioQueueNewOutput`,
  `AudioQueueStart`, `AudioQueueEnqueueBuffer`, and `CMSessionCreate`;
- `FigAudioQueueCreate` was not present through `RTLD_DEFAULT`.

The probe code was removed from the repository after the product path moved to
`audio/`. The retained class dump is `docs/mediaserverd-capture-classes.txt`.

## Known recovery notes

- Restarting `mediaserverd` while SpringBoard capture is active can stall the
  current H.264 session. Audio enable/disable now idles video capture, restarts
  mediaserverd, sends a stream reset, then resumes video when a viewer is still
  connected.
- Direct private SpringBoard idle-reset calls caused SpringBoard crashes in
  earlier builds. The capture path no longer calls those selectors in the hot
  path; it relies on `UIApplication.idleTimerDisabled` and the existing power
  assertion.
- Stopping capture while VideoToolbox encode work was still in flight caused a
  crash in `VTCompressionSessionEncodeFrame`. `rctl_session_stop` now drains the
  capture queue before destroying the session.

## Product direction

The current PCM-over-HTTP stream is correct for LAN validation and debugging.
The professional internet path should evolve to one capture core with multiple
sinks:

- browser realtime: WebRTC media transport, H.264 video RTP, Opus audio RTP,
  DataChannel or authenticated HTTPS/WebSocket for control;
- passive media clients: RTSP/RTP or another ffplay/VLC-friendly sink;
- recording/export: fragmented MP4 or normal MP4 as a separate sink.

Before internet exposure, add authentication and transport encryption. The audio
pipeline is sensitive because anyone who reaches the control endpoint can listen
to device playback.

## Next checkpoints

1. Keep `audio/` as the only runtime audio module and avoid adding more top-level
   experimental targets.
2. Move `/audio_test` to a debug namespace or compile-time debug flag.
3. Replace PCM-over-HTTP with Opus/WebRTC for the internet transport.
4. Split daemon audio lifecycle code into an `AudioCaptureController` once the
   daemon is decomposed into modules.
