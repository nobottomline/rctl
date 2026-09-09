# Remote keyboard delivery

## Text Mode

`web/src/hooks/useControl.ts` maps `KeyboardEvent.code` to keyboard-page HID
usages. Ordinary keys use atomic `d=2` taps; modifiers use `d=1` / `d=0`.
`KeyboardState` tracks only modifiers sent by this page and releases them on
blur, page hide, hidden document, local form/menu focus, and unmount. Local
editable controls, buttons, menus and composition events are not forwarded.
Clicking the device screen restores its focus without scrolling.

`ControlEngine.key` uses the control DataChannel when open, otherwise `/key`.
The daemon forwards both paths over IPC to SpringBoard's `TouchInjector`.
Keyboard-page events currently use `_enqueueHIDEvent:`; the system dispatch
fallback is used only when that route is unavailable. Do not send the same event
through both paths: that previously duplicated passcode digits.

Text mode is text-input support, not hardware-keyboard parity. Atomic taps do not
represent a sustained W press. Changing taps to press/release alone is also
insufficient if the foreground game's keyboard input path never receives them.

## Game Mode

Optional relative mouse capture is a separate service and channel; see
[`POINTER.md`](POINTER.md). It does not change Text mode or duplicate key events.

The control client's **Keyboard > Game** selector uses a separate, opt-in
virtual HID keyboard. `core/input/GameKeyboard.mm` owns an
`IOHIDVirtualServiceClient` inside SpringBoard. It is created only when a
controller acquires it, and removed when that controller releases it or its
lease expires. Ordinary text delivery is unchanged; no event is sent through
both the virtual service and UIKit. No physical-keyboard monitor is registered.

The implementation follows the callback ABI of Apple's
[virtual-service test](https://github.com/apple-oss-distributions/IOHIDFamily/blob/IOHIDFamily-1446.140.2/IOHIDFamilyUnitTests/TestVirtualService.m).
Symbols are resolved at runtime. Missing APIs or failed service creation return
`hardware_keyboard_unavailable`; they do not silently fall back to a route that
cannot deliver held keys. Symbol presence alone does not establish compatibility
of private callback ABIs on every iOS release.

### Contract and Lifecycle

`POST /v1/keyboard` accepts `application/json` up to 2048 bytes. The daemon
forwards query type `RCTL_Q_GAME_KEYBOARD` to SpringBoard's main queue:

- `acquire`: `owner`, a new random 128-bit token encoded as 32 lowercase hex
  characters. Only one Game controller may own the service at a time.
- `state`: the same `owner`, strictly increasing integer `sequence` (1 through
  UINT32_MAX), and the complete `keys` array. At most 32 distinct keyboard-page
  usages are allowed: 4 through 164 and modifiers 224 through 231.
- `release`: the same `owner`. Another controller cannot release the active
  owner's keys. Releasing an already absent service is harmless.

Success includes `ok`, `active`, `lease_ms` (1500) and `sequence`. Request-body
errors are 400; SpringBoard rejection codes currently use 409, including
`keyboard_busy`, `keyboard_not_owned`, `stale_keyboard_sequence` and validation
errors. A missing SpringBoard response returns 504. Clients must inspect the
error code, not infer game delivery from HTTP acceptance.

Accepted state updates renew a 1500 ms monotonic lease; repeated acquisition
does not renew it. A 100 ms SpringBoard timer checks expiration. Release removes
held keys and destroys the service. IPC disconnection also stops it. Expiration
depends on the SpringBoard main queue running; it is not a hard realtime limit.
The ownership token coordinates viewers; it is not an authentication layer.
Existing trusted-LAN and relay authorization policies still apply.

`web/src/lib/gameKeyboard.ts` sends ordered full-state snapshots with one state
request in flight, 400 ms heartbeats, a 1-second request deadline, and at most
16 queued transitions. It preserves short down/up taps and ignores browser
repeat events. Excessive backpressure or delivery failure stops Game mode;
there is no unlimited stale-input replay. Old-session responses cannot reactivate
a disabled session. Blur or local UI focus releases keys; page hide, hidden
document and unmount also release ownership. Device expiry covers lost network
connections even when browser cleanup cannot reach the device.

Game mode currently uses HTTP (or the existing relay HTTP proxy), not the
ordinary key DataChannel. Relay latency has not been qualified for gameplay.
Macro recording/playback switches to Text and prevents enabling Game until
idle: virtual HID states are not silently omitted from an apparently valid
recording. Existing macro key events keep their established delivery semantics.

### Device Evidence (2026-09-09/10)

- The exclusive system-dispatch route was tested inside SpringBoard in
  `rootless8`; the operator confirmed Minecraft still did not respond to W.
- A standalone virtual-service probe sent a short W hold and release. The
  operator confirmed movement, and the test was repeated.
- `rootless9` integrated the service into SpringBoard and added the browser
  selector. After installation and respring, the operator confirmed the browser
  Game mode works in Minecraft on iPadOS 15.5 / Dopamine with Magic Keyboard.
- Real-device API checks verified exclusive ownership, stale-sequence rejection,
  rejection of another owner's release, malformed state rejection, and expiry
  followed by reacquisition. These expiry checks used an empty key set; an
  actual held-key network-loss test is still required.
- Native host lease/validation/header tests and browser state-machine tests pass.
  Both rootless SpringBoard architectures and rootful iOS 14.5 SDK builds compile;
  rootful runtime, operation without a physical keyboard, host-reserved shortcuts
  and full gameplay combinations remain unqualified.
- Final browser checks with keyboard requests intercepted verified held W+A,
  release after local UI focus, and ownership release when selecting Text.
  Desktop and 390 px mobile screenshots showed no menu overflow. These checks
  do not replace the operator's separate real-device gameplay confirmation.
- The final HTML was deployed atomically, with a backup and matching SHA-256,
  over the installed `rootless9` native package. `rootless10` includes this HTML
  and passed build/public-artifact audit, but was not installed through Sileo.

Lowercase HTTP headers discovered during these tests exposed an existing local
POST parsing problem. `HttpHeaders.h` now matches complete header names
case-insensitively, ignores body/request-target matches, and rejects duplicate
lookups. This is a scoped Content-Type/Content-Length fix, not a replacement of
the HTTP parser.

## Earlier Investigation, 2026-09-08

On the iPadOS 15.5 / Dopamine test target with a connected Magic Keyboard:

- The operator reports physical keyboard gameplay and remote text-field input
  work, while remote Minecraft WASD does not.
- A direct `/key?p=7&u=26&d=1`, followed 500 ms later by `d=0`, returned HTTP 200
  for both requests. The operator confirmed no movement. HTTP acceptance is
  therefore not proof of game delivery; this bypassed the browser's tap logic.
- An isolated `IOHIDUserDeviceCreate` probe returned NULL. The symbols and
  `IOHIDResource` service existed; `IOServiceOpen` returned `0xe00002e2`
  (`kIOReturnNotPermitted`). `SecTaskCopyValueForEntitlement` confirmed
  `com.apple.hid.manager.user-access-device` was true. Adding the virtual-device
  and platform-application entitlements did not resolve this standalone-process
  failure. This does not prove that every process or jailbreak rejects the API.
- A separate system-dispatch probe found one keyboard service and submitted a
  short W down/up pair with its registry sender. The operator confirmed no
  movement here either. This was a standalone entitled process, not a test of
  dispatch from SpringBoard or backboardd; it is not a production backend.

No input contents or personal device identifiers were logged. That initial
investigation did not change the native input route or package.

Relevant upstream interfaces:
[IOHIDUserDevice creation](https://github.com/apple-oss-distributions/IOKitUser/blob/main/hid.subproj/IOHIDUserDevice.c),
[IOHID resource access checks](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDResourceUserClient.cpp),
[GCKeyboard](https://developer.apple.com/documentation/gamecontroller/gckeyboard).
Current upstream source is a reference, not proof of an iPadOS 15.5 kernel's
exact implementation.

## Upstream Follow-up (2026-09-08)

Apple's [keyboard and mouse gaming session](https://developer.apple.com/videos/play/wwdc2020/10617/)
distinguishes UIKit input from the Game Controller framework's `GCKeyboard`
callbacks and polled key state. Successful text insertion does not establish
that a game's polled W state changes. This is a plausible explanation for the
reported Minecraft behavior, not an instrumented finding about Minecraft's
particular implementation.

The upstream [ioscpy input implementation](https://github.com/lautarovculic/ioscpy/blob/main/device/tweak/InputInjector.mm)
dispatches keyboard events from SpringBoard using
`IOHIDEventSystemClientDispatchEvent`, without a digitizer/fabricated sender ID.
This differs from both our current UIKit route and the earlier standalone
system-dispatch probe. Its code is a useful next experiment, not proof of game
support on the target jailbreak. A rootless-only build of this exclusive route
compiled and passed the package audit locally, but was not installed or retained
in production source while the Sileo upgrade defect was being investigated.
Do not dual-dispatch as a fallback after an apparently accepted event.

The existing remote typing path also failed to edit Sileo's Add Source field in
this run; the `sileo://source/` URL handler opened the correct prefilled dialog.
Include this real focused-field case in the next input regression test, alongside
ordinary app text fields and single passcode digits (without recording a code).

System shortcuts have a separate host boundary: macOS may consume Cmd+Tab and
Cmd+Q before a browser receives them. Test the device chord directly first, then
provide an explicit controller action if it works. Apple's
[iPad keyboard shortcuts](https://support.apple.com/en-lamr/102393)
documents Cmd+Tab as app switching; Cmd+Q is not a universal iPadOS force-quit
contract. Do not equate an HTTP 200 response with either shortcut taking effect.

## Remaining Release Qualification

1. Verify the integrated Game route with and without a physically attached
   keyboard on both target lanes. Rootless success is not rootful runtime proof.
2. Verify actual held-key release after network loss and tab close, including
   reacquisition by a second viewer. The device lease must remain authoritative.
3. Qualify remote latency before promising relay gameplay or adding a different
   transport. Keep single-owner, ordered snapshots across any future handoff.
4. Provide explicit UI actions for host-reserved shortcuts. macOS can consume
   Cmd+Tab / Cmd+Q before the web page sees them. Sending Cmd+Q must not be
   presented as universal iPadOS app termination; application behavior varies.
5. Qualify held W/A/S/D combinations, modifiers, release after tab close and
   network loss, text input, passcode single-digit input, and macro playback.

## Verified browser regression checks

The 2026-09-08 focus change passed `npm test` (10 tests) and `npm run build`.
Browser checks with device requests intercepted verified atomic W taps,
one Shift release after blur, Control release when a field gains focus, no
forwarded local UI/form keystrokes, and restored forwarding after a screen click.
These checks establish browser behavior only, not game HID delivery or
device-side release after network loss.
The updated HTML was deployed atomically with a backup and compared byte-for-byte
with the local build. A fresh browser session without interception confirmed the
new client and advancing decoded video frames. No native package was replaced.
