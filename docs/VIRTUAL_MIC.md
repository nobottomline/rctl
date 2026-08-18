# Virtual Microphone

`rctl` can route the controlling browser's microphone to either the iPad
speaker, the microphone input consumed by the active calling app, or both. The
browser-to-device transport stays the existing Opus `mic-in` WebRTC DataChannel.

## Data Flow

```text
browser getUserMedia
  -> raw mono capture (calling app owns AEC/NS/AGC)
  -> WebCodecs Opus, mono 48 kHz
  -> reliable mic-in DataChannel
  -> rctld Opus decoder
  -> speaker AudioQueue (speaker/both)
  -> bounded loopback PCM bus :8082 (mic/both)
  -> lazy rctlapp AudioUnitRender hook
  -> rctlappmedia realtime post-processing
  -> RemoteIO / VoiceProcessingIO input buffer
  -> Discord, FaceTime, or another recording app
```

`rctld` decodes each Opus packet once. `/v1/talk_route` selects `speaker`, `mic`,
or `both`; the default after every daemon start is `speaker`, preserving the
previous intercom behavior. The web control center exposes the same three modes.
The same endpoint reports non-content `clients`, `frames_pushed`, and
`frames_broadcast` counters for runtime diagnosis.

## App-Side Injection

`rctlapp` is the original Substitute-loaded UIKit tweak. It does not hook
`AudioUnitRender` at process startup: doing so broke RemoteIO initialization on
the target iOS 14 arm64e device. The first virtual-mic PCM burst posts a Darwin
notification, and only the active foreground app installs the hook. The hook
calls the original render first, then invokes the optional processor exported by
the manually loaded `rctlappmedia.dylib`. SpringBoard never loads that payload.

`app/VirtualMicClient.mm` owns the processor. It considers only bus 1, the proven
RemoteIO/VoiceProcessingIO input element. Format and component queries run on a
worker thread. Until that query completes, the realtime path can infer common
float32 or signed-int16 layouts directly from the provided `AudioBufferList` and
uses the device's proven 48 kHz rate. Other buses and unsupported layouts are
left untouched.

The shim supports mono or multichannel, interleaved or non-interleaved Linear
PCM in float32, signed int16, and signed int32/fixed-point formats. The
allocation-free `core/audio/VirtualMicDSP` resamples incoming mono 48 kHz PCM to
the application's capture rate and the app shim copies it to every requested
channel. Its unit test covers resampling, underflow, backlog, and discontinuity
behavior independently of the iOS hook.

The audio callback never takes a mutex, allocates, creates a thread, queries an
AudioUnit, opens a socket, or logs. Activation creates the format and receiver
workers before installing the hook. The receiver writes into a two-second atomic
ring; the consumer drops stale backlog to keep latency near 60 ms.

## Failure Behavior

- No virtual PCM, an underflow, an unsupported format, or data older than 600 ms
  leaves the real microphone buffer unchanged.
- The active app connects to the loopback bus when Talk begins and disconnects
  after ten seconds without input renders.
- The daemon queue is bounded to eight frames; slow clients are disconnected.
- Switching to `speaker` stops new virtual-mic PCM immediately. Existing short
  ring content drains, then the physical microphone remains in use.
- SpringBoard is excluded from injection.

The browser requests raw mono input. Browser-side echo cancellation, noise
suppression, and automatic gain are disabled because Discord/FaceTime/the target
calling app applies voice processing after injection; applying both stages can
erase or distort the source before it reaches the iPad.

The PCM listener binds only to `127.0.0.1`; it is not reachable from Wi-Fi or the
relay. The relay/browser still requires the normal authenticated device session.
On a jailbroken device, arbitrary malicious local code remains inside the same
host trust boundary and could attempt to attach to loopback services.

## Qualification

Compilation is necessary but not sufficient because calling apps choose their
own AudioUnit format and processing path.

Physically verified on iPad11,3 / iOS 14.4 with Voice Memos:

- physical-mic recording works before the first Talk;
- a browser-generated 1 kHz WebAudio stream traverses WebCodecs Opus,
  DataChannel, daemon decode, loopback, app injection, and the recorded M4A;
- the recorded 1 kHz band measured -18.7 dB versus -62.4/-62.7 dB at 500/2000
  Hz, a minimum 43.7 dB separation;
- stopping Talk returns to the physical input without reloading the app;
- recording remains live while the hook activates, with no RemoteIO watchdog
  termination.

Still required before calling the feature generally qualified:

1. Discord voice call with `App mic`: the remote participant hears browser
   speech without device-speaker leakage.
2. Discord with `Both`: app input and device speaker both receive the stream.
3. Switch apps during a call, interrupt and resume the audio session, lock and
   unlock the device, and reconnect WebRTC.
4. Exercise 44.1 kHz input routes, Bluetooth if it is a supported
   product scenario, and at least one VoiceProcessingIO client.
5. Confirm that closing the tab and restarting `rctld` fail
   back to the physical microphone.
