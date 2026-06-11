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
3. Add an in-daemon audio ring-buffer/packet API with a synthetic test source.
4. Replace the synthetic source with an in-daemon audio ring-buffer/packet API.
5. Only then attempt a real system-audio tap.
