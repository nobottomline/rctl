# Virtual Microphone

`rctl` can route the controlling browser's microphone to either the iPad
speaker, the microphone input consumed by the active calling app, or both. The
browser-to-device transport stays the existing Opus `mic-in` WebRTC DataChannel.

## Data Flow

```text
browser getUserMedia
  -> WebCodecs Opus, mono 48 kHz
  -> reliable mic-in DataChannel
  -> rctld Opus decoder
  -> speaker AudioQueue (speaker/both)
  -> bounded loopback PCM bus :8082 (mic/both)
  -> rctlapp AudioUnitRender hook
  -> RemoteIO / VoiceProcessingIO input buffer
  -> Discord, FaceTime, or another recording app
```

`rctld` decodes each Opus packet once. `/v1/talk_route` selects `speaker`, `mic`,
or `both`; the default after every daemon start is `speaker`, preserving the
previous intercom behavior. The web control center exposes the same three modes.

## App-Side Injection

`app/VirtualMicClient.mm` is part of `rctlapp`, which is injected into UIKit
applications. It calls the original `AudioUnitRender` first and only replaces
bus 1 for RemoteIO or VoiceProcessingIO. Other AudioUnits and buses are left
untouched.

The shim supports mono or multichannel, interleaved or non-interleaved Linear
PCM in float32, signed int16, and signed int32/fixed-point formats. The
allocation-free `core/audio/VirtualMicDSP` resamples incoming mono 48 kHz PCM to
the application's capture rate and the app shim copies it to every requested
channel. Its unit test covers resampling, underflow, backlog, and discontinuity
behavior independently of the iOS hook.

The audio callback never takes a mutex, allocates, opens a socket, or logs. A
receiver thread owns networking and writes into a two-second atomic ring. The
consumer drops stale backlog to keep latency near 60 ms.

## Failure Behavior

- No virtual PCM, an underflow, an unsupported format, or data older than 600 ms
  leaves the real microphone buffer unchanged.
- The app connects lazily only after a real microphone render is observed and
  disconnects after ten seconds without input renders.
- The daemon queue is bounded to eight frames; slow clients are disconnected.
- Switching to `speaker` stops new virtual-mic PCM immediately. Existing short
  ring content drains, then the physical microphone remains in use.
- SpringBoard is excluded from injection.

The PCM listener binds only to `127.0.0.1`; it is not reachable from Wi-Fi or the
relay. The relay/browser still requires the normal authenticated device session.
On a jailbroken device, arbitrary malicious local code remains inside the same
host trust boundary and could attempt to attach to loopback services.

## Qualification

Compilation is necessary but not sufficient because calling apps choose their
own AudioUnit format and processing path. Before release, verify on the target
iOS version:

1. Voice Memos with `App mic`: browser speech is recorded and physical speech
   returns within one second after Talk stops.
2. Discord voice call with `App mic`: the remote participant hears browser
   speech without device-speaker leakage.
3. Discord with `Both`: app input and device speaker both receive the stream.
4. Switch apps during a call, interrupt and resume the audio session, lock and
   unlock the device, and reconnect WebRTC.
5. Exercise 44.1 kHz and 48 kHz input routes, Bluetooth if it is a supported
   product scenario, and at least one VoiceProcessingIO client.
6. Confirm that disabling Talk, closing the tab, and restarting `rctld` all fail
   back to the physical microphone.
