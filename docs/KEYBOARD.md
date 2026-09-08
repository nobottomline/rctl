# Remote keyboard delivery

## Current implementation

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

This is text-input support, not hardware-keyboard parity. Atomic taps do not
represent a sustained W press. Changing taps to press/release alone is also
insufficient if the foreground game's keyboard input path never receives them.

## Physical investigation, 2026-09-08

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

No input contents or personal device identifiers were logged. The native input
route and native package were not changed by this investigation.

Relevant upstream interfaces:
[IOHIDUserDevice creation](https://github.com/apple-oss-distributions/IOKitUser/blob/main/hid.subproj/IOHIDUserDevice.c),
[IOHID resource access checks](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDResourceUserClient.cpp),
[GCKeyboard](https://developer.apple.com/documentation/gamecontroller/gckeyboard).
Current upstream source is a reference, not proof of an iPadOS 15.5 kernel's
exact implementation.

## Required before held-key support ships

1. Establish and test a genuine hardware-keyboard delivery path in the process
   that is authorized to use it. Preserve SpringBoard's input ownership, and
   verify with and without a physically attached keyboard on both target lanes.
2. Keep text mode compatible. Introduce held-key state only with a bounded
   device-side lease, key-up on disconnect, and explicit ownership between
   simultaneous viewers. A browser blur callback alone cannot release keys
   after a severed network connection.
3. Preserve event ordering in the HTTP fallback and across transport handoff.
   Currently independent HTTP key requests do not provide that guarantee.
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
