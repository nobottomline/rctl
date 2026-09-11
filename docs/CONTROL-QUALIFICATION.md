# Control Qualification

## September 2026 Rootless Follow-up

This is a qualification record, not a claim that every feature works on every
jailbreak. Rootful iOS 14 remains a separate physical regression target.

Implementation: `c323832`. The `0.3.4~rootless3` test package was installed on
iOS 15.5 with a watched rollback window; live video and SpringBoard IPC recovered
and the installation was explicitly verified. Rootful and rootless packages both
passed their public-artifact audits. `make test`, the four web macro tests, and
the TypeScript/production web build passed. Console was inspected in a real
browser at desktop and 390-pixel widths. These checks do not close the remaining
physical-device qualification items below.

### Device Orientation

`GET /v1/orientation` reads `{supported, locked, orientation}`. A
`POST application/json` with `{"orientation":0..4}` requests automatic rotation
(0) or a system orientation lock (1 portrait, 2 upside down, 3 landscape left,
4 landscape right). This changes SpringBoard's orientation policy, not the
browser's presentation transform. The ordinary `/orient` stream and browser
Auto/Rotate controls are unchanged.

The request uses a guarded `SBOrientationLockManager` in SpringBoard over IPC.
Missing selectors return 503; missing IPC replies return 504; invalid values
return 400. Rotation is asynchronous: the response's `orientation` is the observed
orientation at acknowledgement, not a promise that the animation has finished.
Applications may still restrict their supported orientations. Return to 0 to
release the system rotation lock. Portrait and landscape transitions and return
to Automatic were checked on iOS 15.5 without stopping the screen stream.

### Input and Automation

Keyboard events use one delivery path. Sending a keyboard event through both
SpringBoard's enqueue method and the HID client duplicated passcode digits on
iOS 15.5. The owner confirmed single-digit entry after the change. Consumer keys
retain the HID client path; missing enqueue selectors fall back to it.

Touch/key playback pauses at a neutral input boundary: an in-flight gesture
finishes before the clock freezes. Stop releases held fingers/modifiers. Export
produces a JSON `{actions:[...]}` script with waits and raw `input` / `input_key`
events, preserving the recorded normalized coordinates and millisecond timing.
The exported script can be pasted into Console's Script section or posted to
`/v1/script`. Playback timing remains best-effort, not hard realtime.

The daemon preflights the whole script before scheduling any action. Supported
types are `wait`, `tap`, `swipe`, `type`, `button`, `key`, `launch`, `input`, and
`input_key`. Unknown types and malformed fields now fail instead of being silently
skipped. Bounds are 10,000 actions, one hour total scheduled duration, ten minutes
per wait, and one minute per swipe. Export adds releases for unfinished gestures.

**Not yet universal:** scripts do not wrap every REST endpoint. A future executor
must define sequential responses, error/timeout propagation, cancellation, media
leases, and explicit destructive confirmations. Do not bypass these boundaries
by adding an unrestricted URL runner or automatically minting confirmation tokens.

### Other Fixes and Evidence

- Rootless `DynamicLibraries` aliases `TweakInject`. Enumerating the resolved
  directory once removes duplicates. `rctlapp` and `rctlsbcap` remain distinct
  injection payloads belonging to one package; Packages is the package-level view.
- Mic recording creates its data directory independently of the packaged web
  location, checks capture/writer startup, and stores the file with mode 0600.
  A real 27-second recording produced 289,606 bytes; it was stopped and discarded.
  The browser no longer claims success when recording start fails.
- The terminal's POSIX prompt and commands were verified over its real WebSocket.
- Console screenshots now preview before an explicit download. The object URL
  is released on replacement/unmount. Volume is read through audio-output status.
- Custom alerts no longer replace an empty title with `rctl`; the OK dismissal
  remains. Fully empty title/body needs device UI verification.
- Media replaces the main Photos launcher; Copy/Share visibility follows actual
  browser capabilities. Plain LAN HTTP cannot enable secure-context APIs.
- Pointer hover treatment does not change element dimensions or touch behavior.
- Video thumbnails now use existing Photos posters on the tested iOS 15.5
  device; see `MEDIA.md` for the physical verification and fallback limits.

### Audio Noise Investigation

The owner reports intermittent noise across apps, including paused playback.
Code inspection found unchecked planar buffer lengths and ignored AudioUnit
silence flags. Capture now validates packed S16/F32 layouts, per-plane bounds,
finite float samples, and does not transmit unspecified silent-render storage.
Host tests cover these bounds. This is a concrete defect fix, not yet proof that
all intermittent noise is eliminated. Remaining work includes sustained device
listening, source selection across simultaneous AudioUnits/AudioQueues, and
bounded browser playout queues. Do not tune gains to conceal invalid PCM.

### Web Interaction Follow-up

Orientation uses the existing Radix dropdown dependency with radio selection,
keyboard navigation, Escape dismissal and focus restoration. Hover styling is
component-scoped and colour-only, not a global button outline or scale transform.
Identifier rows are selectable text; only their fixed-size copy buttons act on
click. Successful text copying shows a temporary checkmark; failed copying never
does. Plain HTTP uses a checked text-copy fallback. Clipboard tests and browser
checks cover failure, focus restoration, mobile menu placement and stable hover
metrics. This web-only update does not change native input or orientation IPC.

### Remaining Qualification

- Confirm no recurring Listen noise over sustained playback and silence.
- Confirm lock-screen keypad visibility separately from corrected key duplication.
- Exercise front/back camera, room audio, macro playback and new controls on the
  original rootful device when it is reachable.
- Expand scripts only with the execution and confirmation model described above.
