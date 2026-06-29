# Room-mic "Listen" resprings the device

**Status:** open (device-side). System-audio Listen is unaffected and stable.
**Severity:** high — enabling mic Listen crashes the iPad (~5–8 s), repeatedly.
**Component:** `rctld` daemon mic capture (`daemon/main.mm`) + iOS audio stack.

## Symptom

A few seconds (~5–8 s) after the browser enables **"Listen" for the room
microphone** (the iPad's own mic, the `room-mic` channel — *not* the system-audio
tap), the iPad **resprings**: black screen + spinner, then the Home screen. The
video stream freezes/stops during the respring and recovers a couple of seconds
later once `rctld` and SpringBoard come back.

Reproduces **both over the relay and on the local LAN path**, and **with nothing
else running** — no TikTok, no system-audio Listen. The single trigger is the
room-mic capture.

It only started being observed once the browser-side Opus decode was fixed (see
`[[webrtc-transport]]` memory: WebCodecs `AudioDecoder` is absent on iOS Safari
< 26, and the CSP blocked the WASM fallback). Before that, mic Listen never
produced audio, so the daemon-side mic capture was rarely exercised end-to-end.
The capture bug is **pre-existing**; finishing the decode path merely exposed it.
It is **not** a web bug and **not** a memory leak in the browser.

## Root cause

`room-mic` is captured **daemon-side via a RemoteIO Audio Unit input**:

- Browser "Listen (mic)" → `GET /v1/mic_capture?on=1` → sets `g_micListenWant`
  (`daemon/main.mm`).
- The daemon opens its **own** `kAudioUnitSubType_RemoteIO` unit with input
  enabled (`g_micUnit`, ~`daemon/main.mm:1722–1744`); the render callback
  `rctl_mic_input_cb` pulls mic PCM → `rctl_webrtc_push_mic` → Opus → `room-mic`
  DataChannel.

Opening a **RemoteIO input from a daemon** forces the global audio session/route
toward **recording**. That route change makes **mediaserverd reconfigure**, and:

1. The shared **H.264 `VTCompressionSession` is serviced by mediaserverd**, so it
   gets invalidated — `rctl-enc.log` spams `rebuild err=-12912` (`kVTInvalidSessionErr`),
   i.e. the encoder self-heal (`core/encode/H264Encoder.mm` output-stall watchdog)
   firing over and over.
2. The daemon's **own RemoteIO unit loses its mediaserverd context** and `rctld`
   dies. In the logs `rctld`'s PID churns right after each `miccap: started`
   (e.g. `24050 → 24095 → 24123 → 24134`).
3. The crash + audio-stack thrash **cascades into a SpringBoard respring**
   (SpringBoard, `rctld`, and mediaserverd all restart within seconds of each
   other; `backboardd` does not).

This is an **architectural conflict** between the daemon's RemoteIO mic input and
the mediaserverd-hosted encode/audio pipeline — not a one-line bug.

## Evidence (device logs)

```
# rctld.log — "started" immediately followed by a respawn (new pid)
[.. pid=24050] miccap: started (daemon RemoteIO input)
[.. pid=24095] miccap: started (daemon RemoteIO input)   # pid changed -> rctld restarted
[.. pid=24123] miccap: started (daemon RemoteIO input)   # again

# rctl-enc.log — encoder VT session invalidated repeatedly while mic capture runs
rebuild err=-12912 pending=2          # -12912 = kVTInvalidSessionErr
rebuild err=-12912 pending=1
...

# process start times after a respring — all three restarted together
SpringBoard  : ~3m37s elapsed
rctld        : ~3m38s elapsed
mediaserverd : ~3m19s elapsed
backboardd   : 6 days  elapsed        # NOT restarted
```

There are **no fresh `.ips` crash reports** for the respring — consistent with a
jetsam/cascade kill rather than a clean SIGSEGV (cf. the `[[rctld-memory-limits]]`
note that jetsam kills leave no `.ips` and just change the PID).

## Why system-audio Listen is fine but room-mic is not

System audio ("Listen" to whatever is playing) is captured by the **mediaserverd
tap** (`audio/rctlaudio.xm`, hooks `AudioUnitRender`/`AudioQueueEnqueueBuffer`),
which only **reads** the output mix already flowing through mediaserverd. It does
not request an input/recording route, so it doesn't trigger the recording
reconfiguration that breaks the daemon's RemoteIO unit. (Its earlier
"audio-freezes-video" issue — enabling the tap restarts mediaserverd and kills the
encoder — was fixed by the encoder self-heal watchdog; see `[[webrtc-transport]]`.)

## Fix options

1. **Interim (cheap, safe — recommended for the public release):** hide/disable
   the mic-"Listen" control in the web UI so no one resprings the device by
   accident. System-audio Listen stays. (Pure web change.)
2. **Proper fix (significant device work, respring risk):**
   - Make the daemon RemoteIO input **resilient to mediaserverd restarts**: detect
     the unit invalidation (render errors / `-12912`-class status), and cleanly
     `AudioOutputUnitStop` + dispose + re-create the unit instead of dying. Needs a
     real crash backtrace to confirm where `rctld` actually faults (none captured
     yet — jetsam/no `.ips`; may need a manual symbolicated catch or `os_log`
     around the unit calls).
   - Or **move mic capture out of the conflict** — capture the mic from a context
     that doesn't fight the mediaserverd-hosted encoder, or coordinate the audio
     session so input + encode coexist.

## Related

- Audio decode fix that surfaced this: commits `76602e1` (WASM Opus fallback) +
  `62df5b8` (CSP `wasm-unsafe-eval`).
- Encoder self-heal on mediaserverd restart: `core/encode/H264Encoder.mm`.
- System-audio tap: `audio/rctlaudio.xm`.
