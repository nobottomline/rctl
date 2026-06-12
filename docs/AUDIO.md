# Audio Architecture Notes

Goal: stream what the iPad is actually playing, for example YouTube audio, to a
browser or native media client together with the screen stream.

## Current baseline

- Video and touch work over the existing LAN HTTP/WebCodecs path.
- Video frames now carry real `pts_us` presentation timestamps from VideoToolbox
  through SpringBoard IPC, `rctld`, and the browser decoder.
- The current stream frame parser ignores unknown frame types, so future audio
  frames can be added without making old video clients feed them to WebCodecs.
- `/audio_test?on=1&hz=440` enables a synthetic daemon-generated PCM test tone.
  It sends `/stream` frame type `4` with payload
  `[8B BE pts_us][4B BE sample_rate][1B channels][1B bytes_per_sample][2B BE frames][s16le PCM]`.
  The browser panel's `Tone` button unlocks Web Audio and renders these frames.
  This validates audio framing, timestamps, browser scheduling, and playback
  without touching system playback capture.
- `rctl_http_push_pcm_s16le()` is the transport contract for future capture
  sources. It accepts interleaved mono/stereo S16LE packets and hides HTTP
  chunking from the eventual system-audio tap.
- `/var/run/rctl-audio.sock` is the daemon-side ingest socket for audio sources
  outside SpringBoard, such as a future `mediaserverd` tap. The IPC frame type is
  `RCTL_MSG_AUDIO` and its payload is the same PCM packet described above.
- `127.0.0.1:8079` accepts the same raw audio ingest frames as a localhost-only
  fallback for sandboxed processes that cannot connect to `/var/run` Unix
  sockets. The mediaserverd skeleton tries Unix first and falls back to TCP.
- `audiosource/` contains a diagnostic-only mediaserverd source skeleton. It is
  not part of the normal package and has no hooks. When explicitly loaded with
  `/tmp/rctl-audiosource-tone` present, it sends a short synthetic PCM stream to
  the ingest socket so we can validate the future capture-process boundary.

## Non-goals

- Do not use the microphone as the answer for playback audio. It captures room
  sound, speaker echo, volume-dependent output, and silence when the device is
  routed to headphones.
- Do not put the system-audio experiment inside SpringBoard. A bad audio hook
  must not respring the UI or break input/video control.
- Do not kill or restart `mediaserverd` while a viewer is connected. Prior camera
  reverse engineering showed that disrupting it can crash active media paths.

## Device findings

Target device: iPad11,3 on iOS 14.4. Audio service ownership appears to be inside
`mediaserverd`; there is no separate `coreaudiod` process on this device. Relevant
rootfs surfaces:

- `/usr/sbin/mediaserverd` is a real Mach-O and links `AudioToolbox`,
  `MediaToolbox`, and `CoreMedia`.
- Private framework directories exist for `AudioServerApplication`,
  `AudioServerDriver`, `AudioSession`, `AudioToolboxCore`, `MediaExperience`, and
  `Celestial`, but many binaries are dyld-shared-cache residents rather than
  standalone files.
- The existing mediaserverd class dump contains useful audio classes and methods:
  `Core_Audio_Daemon`, `AVAudioSession`, `FigCaptureAudioDataSinkPipeline`,
  `BWAudioSourceNode`, `FigAudioCaptureConnectionConfiguration`, and related
  audio file/data sink configurations.

## One-shot probe result

`scripts/audioprobe.sh once` was run on the iPad with no active browser viewer.
The script activated `rctlaudioprobe`, restarted `mediaserverd`, captured the log,
removed the active probe dylib/plist, and restarted `mediaserverd` cleanly.

Observed in `mediaserverd`:

- Classes present: `Core_Audio_Daemon`, `AVAudioSession`, `AVAudioPlayer`,
  `AVAudioRecorder`, `AVCaptureAudioDataOutput`, `AVCaptureFigAudioDevice`,
  `BWAudioSourceNode`, `FigAudioCaptureConnectionConfiguration`,
  `FigCaptureAudioDataSinkConfiguration`, `FigCaptureAudioDataSinkPipeline`,
  `FigCaptureAudioFileSinkConfiguration`, `FigCaptureAudioFileSinkPipeline`.
- Symbols present: `AudioComponentFindNext`, `AudioComponentInstanceNew`,
  `AudioOutputUnitStart`, `AudioOutputUnitStop`, `AudioUnitGetProperty`,
  `AudioUnitSetProperty`, `AudioUnitRender`, `AudioQueueNewOutput`,
  `AudioQueueStart`, `AudioQueueEnqueueBuffer`, `CMSessionCreate`.
- `FigAudioQueueCreate` was not present through `RTLD_DEFAULT`.

Operational note: after restarting `mediaserverd`, one `/stream` attempt returned
only the cached keyframe. Sending `/config?scale=1.0&fps=30&bitrate=24000000`
forced SpringBoard to recreate the capture/VideoToolbox session, after which
live frames resumed normally. This reinforces the rule: do not probe/restart
`mediaserverd` while a real viewer session is active.

## Audio-source skeleton result

`scripts/audiosource.sh once` was run with no active browser viewer. The script
activated `rctlaudiosource`, restarted `mediaserverd`, captured the log, removed
the active dylib/plist/marker, and restarted `mediaserverd` cleanly.

Observed:

- `mediaserverd` cannot connect to `/var/run/rctl-audio.sock`; connect fails
  with `errno=1 Operation not permitted`.
- The same process can connect to the daemon's localhost TCP ingest fallback
  (`127.0.0.1:8079`).
- The skeleton sent `150` synthetic PCM packets through that TCP path.
- `rctld` logged `audio tcp source connected` and `audio tcp source disconnected`.
- A post-test H.264 sample still contained live key/delta frames and probed as
  `h264 1668x2224 25/1`.

## Real playback capture probe

An opt-in `audiosource` capture run was tested in `mediaserverd` using
`/tmp/rctl-audiosource-capture`. The active dylib/plist/marker were removed
after the probe and `mediaserverd` was restarted cleanly.

Observed:

- Hooks installed for `AudioQueueEnqueueBuffer`,
  `AudioQueueEnqueueBufferWithParameters`, and `AudioUnitRender`.
- During `/v1/say` plus `/v1/sound`, `/stream` received real audio frame type
  `4`: `80` packets, first packet `48000 Hz`, `2` channels, `1024` frames.
- This confirms the viable capture boundary is inside `mediaserverd`, and the
  source can feed `rctld` over `127.0.0.1:8079`.
- Capture mode is guarded by an internal `180` second TTL watchdog. If the
  diagnostic dylib is accidentally left loaded, it stops accepting new PCM after
  the TTL and drains/stops its worker thread.

Recovery note:

- A SpringBoard crash occurred after manually forcing `/config` while recovering
  from the probe. Symbolication showed `rctlsbcap.dylib` crashed in
  `rctl_capture_wake_display` at the direct `SBSUndimScreen` call.
- The fix is to avoid direct `SBSUndimScreen` and use SpringBoard/UIKit idle
  reset selectors instead.
- Post-fix deployment was verified: package status `install ok installed`,
  no new SpringBoard crash report, `SB connected`, and H.264 sample
  `1668x2224 25/1` with key/delta frames.
- A later crash on `2026-06-12 16:31:43 +0300` again symbolicated to
  `rctl_capture_wake_display`, this time through the replacement
  `resetIdleTimerAndUndim*` path during capture start/reconfigure. Those private
  idle-reset selectors are no longer used in the hot path; capture now only sets
  `UIApplication.idleTimerDisabled` and keeps the existing power assertion.
  Deployment `0.3.0-101+debug` was verified with `/stream` producing
  `1668x2224 25/1` H.264 key/delta frames and no new SpringBoard crash report.
- Real audio capture is now controlled by `rctld` through
  `/v1/audio_capture?on=1|0|status=1`. The package ships the mediaserverd
  source as an inactive payload under `/usr/local/lib/rctl/audio`; active
  MobileSubstrate files and markers are created only on explicit enable and are
  removed on disable, daemon startup, install, and viewer idle cleanup.
- A crash on `2026-06-12 16:51:56 +0300` symbolicated to
  `VTCompressionSessionEncodeFrame` on `com.greatlove.rctl.capture`. The cause
  was stopping a capture session by cancelling its dispatch timer and immediately
  destroying the VideoToolbox session/IOSurface while an encode block could still
  be in flight. `rctl_session_stop` now drains the capture queue before destroy.
- Restarting `mediaserverd` while SpringBoard capture is active can stall the
  current H.264 session. Audio capture enable/disable now temporarily idles video
  capture, restarts `mediaserverd`, sends a stream reset, then resumes video if a
  viewer is still connected. Deployment `0.3.0-109+debug` was verified with
  audio capture active, `capture packets sent=1750 dropped=0`, live H.264
  key/delta frames, and no new SpringBoard crash report.

## Preferred product architecture

Use one capture core with multiple sinks:

- **Realtime browser/client:** WebRTC media transport.
  - Video: H.264 RTP track from the existing VideoToolbox encoder.
  - Audio: Opus RTP track from system playback PCM.
  - Control: DataChannel or authenticated HTTPS/WebSocket for touch, keyboard,
    config, clipboard, and automation.
- **Passive media clients:** RTSP/RTP or another ffplay/VLC-friendly sink over the
  same encoded media core.
- **Recording/export:** fragmented MP4 or normal MP4 as a separate sink, not as
  the realtime transport.

## Audio source strategy

The real source we need is system playback PCM after app decode/mix and before
speaker/Bluetooth output. Candidate approaches, in order:

1. **Read-only mediaserverd/audio-server probe.** Build a diagnostic that can be
   injected only on demand, logs loaded classes/symbol availability, and exits
   without modifying render paths. This should not ship enabled by default.
2. **AudioToolbox/CoreAudio render tap.** Find a stable render/mix/output callback
   boundary, copy PCM into a lock-free ring buffer, and immediately return to the
   system render path. No blocking, allocation, or network I/O on the audio thread.
3. **Encoder/transport bridge.** A separate daemon-side worker drains PCM, resamples
   to 48 kHz if needed, packetizes 10-20 ms frames, and feeds Opus/WebRTC or an
   RTSP/RTP sink.

## Safety rules

- Audio hooks are opt-in and isolated from the default SpringBoard package path.
- Any hook in `mediaserverd` must be reversible and guarded by a watchdog.
- The audio render callback may only copy to preallocated memory and update
  atomics. Encoding and socket writes happen elsewhere.
- Keep a monotonic media clock shared with video. `pts_us` is the unit across the
  local pipeline; WebRTC/RTP timestamp mapping happens at the transport boundary.

## Next implementation checkpoints

1. Add a diagnostic-only audio probe target that is not loaded by default.
2. Confirm process/class/symbol surfaces on the real iPad without altering audio.
3. Add an in-daemon audio packet API with a synthetic test source.
4. Validate the diagnostic mediaserverd source skeleton end-to-end, then remove
   it from the active MobileSubstrate path.
5. Convert the diagnostic real capture hook into a guarded audio-source service:
   preallocated queue/ring buffer, watchdog, explicit enable/disable, and
   reliable reconnect to `rctld`.
6. Add output routing control: browser only, iPad only, or both.
7. Move the realtime browser path from PCM-over-HTTP to Opus/WebRTC once the
   capture source is stable.
