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
- Browser capture starts are cancellable while permission, AudioContext resume,
  or codec capability checks are pending. Cancellation and channel replacement
  release acquired tracks; delayed completion must not restart capture.
- Each Talk attempt owns one channel generation. A closing old channel or a late
  encoder callback cannot stop or send audio into a newer attempt. Reconnection
  never silently resumes microphone capture.
- The control center reports permission, unavailable input, 48 kHz context,
  suspended audio, Opus encoding, and channel failures instead of silently
  reverting the Talk button. Encoder failures and track removal stop capture.

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

### Rootless Talk Investigation (2026-09-11)

The operator reported that Safari Talk briefly activates then stops for the
rootless iPad Pro, while the rootful iPad works. The rootless daemon had not
restarted after the attempts. Both devices use the relay's shared control HTML;
this symptom is not, by itself, proof of a rootless AudioQueue failure.

A Chrome UI comparison used a quiet synthetic browser source rather than the
operator's microphone. Speaker mode sent approximately 250 Opus packets in five
seconds on each device, with the microphone channel open and encoder configured.
Rootless daemon logs confirmed persistent AudioQueue startup and a Talk burst.
The Pro's original `both` route was restored after testing `speaker`. This is
transport/startup evidence, not an acoustic recording or an app-mic qualification.

The browser implementation had reproducible lifecycle defects: an old channel's
close callback always stopped Talk, pending microphone permission could outlive
Stop, and stale encoder errors could affect a subsequent attempt. Generation
guards and cancellable startup now cover these cases. Unit tests also cover
permission denial, unsupported Opus, source removal, graph failure, and resume
cancellation. The new client was checked against both real devices by replacing
HTML only in the test browser, without replacing production assets. An injected
asynchronous encoder failure verified the visible error and capture cleanup.

The original Safari symptom still requires verification with the updated web
client. Do not claim it fixed solely from the Chrome test or attribute it to
the lifecycle defects without observing the Safari failure reason.

The subsequent two-tone test exposed a separate speaker failure: approximately
500 Opus packets traversed the real production control UI in two bursts, but the
operator heard neither tone on the Pro. YouTube paused during the attempt. This
confirms that successful transport and an activation log are insufficient;
it does not establish that Safari caused the silence. The observed mediaserverd
start preceded this process's first speaker queue creation, so a later media
services restart has not been demonstrated as the cause.

The speaker path now checks category/activation results and queue creation,
volume, reset, allocation, enqueue, running-state and start results. The first
buffer is enqueued before starting a stopped queue, including a persistent queue
stopped between bursts. Queued PCM is bounded to half a second. Enqueue failure
frees the unaccepted buffer; a speaker failure restores the volume and suppresses
further attempts until an idle gap, without disabling the independent app-mic
route. Existing persistent-queue behavior is retained for the iOS 14 lane.

Logs contain operation/status codes and cumulative enqueued/returned buffer
counts, never PCM. Returned buffers are not proof of playback: reset also returns
them. `bash scripts/test-webrtc-ownership.sh` exercises production speaker code
with real Opus and fake AudioQueue failures, including interrupted/repeated Talk,
allocation ownership, bounded backlog and retry behavior. Both package lanes
build and pass the public-package audit. Acoustic verification of the new native
path and real Safari microphone capture are still required. No production relay
HTML was replaced during these tests.

On-device follow-up found that the first attempt reached the half-second queue
capacity before buffers were returned; the second attempt drained normally.
The operator heard one tone, believed to be the second. Capacity pressure is now
handled separately from failure: excess incoming PCM is dropped without growing
the queue or cancelling Talk, allowing asynchronous startup to finish. Only two
seconds without buffer-return progress while capacity is exhausted fails the
speaker attempt. Mock tests cover bounded warmup, automatic continuation after
the first callback and a genuine stall. First-attempt acoustic verification is
still pending; neither queue callbacks nor the user's qualified observation
establish complete rootless/Safari support.

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
