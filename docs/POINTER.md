# Remote Mouse Capture

## Ownership and UX

In the control center select **Keyboard > Game**, then **Capture mouse**.
The click requests browser Pointer Lock before any asynchronous work. The
controller then acquires a SpringBoard-owned virtual mouse over WebRTC. The
control menu closes after acquisition. Escape releases browser capture; blur,
hidden document, channel loss and teardown clear the pointer session. Text mode
and macro recording/playback also stop capture.

Ordinary pointer interaction remains touch emulation when capture is off.
While captured, movement sends relative mouse deltas, clicks send HID button
state, and wheel input sends vertical scroll. The capture click itself is not
forwarded as a game click. There is no direct framebuffer-coordinate conversion
and no app-specific hook in Minecraft. The game decides whether to lock its own
cursor, show a pointer, or use relative movement for camera control.

The browser and iPad locks are different: browser Pointer Lock keeps the local
cursor in the control page; iPadOS/game mouse handling consumes the HID events.
System-reserved macOS shortcuts and multi-finger trackpad gestures are outside
this feature. A browser without Pointer Lock or a device without the new
DataChannel shows capture unavailable. The HTTP/WebCodecs-only path does not
enable remote mouse capture.

## Runtime

- `core/input/GamePointer.mm`: optional virtual Generic Desktop mouse service
  inside SpringBoard, resolved through IOKit symbols at runtime. Kept independent
  from the already-qualified keyboard backend during initial mouse qualification.
- `core/input/PointerEvents.h`: relative pointer events with explicit press/release
  children, normalized to the changed HID button numbers. Tracks successfully
  emitted state separately so cleanup releases buttons after a partial failure.
- `core/input/PointerLease.h`: exclusive ownership, monotonic sequence, button
  state, and expiry. No physical input monitoring is installed.
- `core/net/WebRTCBridge.cpp`: creates `pointer` and `pointer-motion` only for `deviceControl` peers;
  weak reply targets and bounded in-flight work survive channel teardown.
- `daemon/main.mm`: bounded asynchronous requests to `RCTL_Q_GAME_POINTER`.
- `web/src/lib/gamePointer.ts`: correlation, coalescing, backpressure and cleanup.
- `web/src/hooks/useControl.ts`: browser capture, input routing and lifecycle.

See [`pointer-v1.md`](../protocol/datachannel/pointer-v1.md) for the wire contract.
No new library, server or relay configuration is required. The existing WebRTC
connection carries the channel, but high-latency relay play must be qualified
separately. Unsupported private APIs return an error; missing symbols do not
activate a fallback or affect ordinary touch/keyboard control. Binary/private-ABI
compatibility still requires real-device tests for each supported iOS lane.

## Qualification

On 2026-09-10, an isolated virtual mouse probe on iPadOS 15.5 / Dopamine sent
relative X movement with no pressed buttons. Minecraft displayed its mouse
crosshair and changed view direction; the operator independently confirmed the
turn. The helper then removed its service. This establishes the virtual-service
route, not yet every integrated browser function.

The initial rootless11/12 browser implementation put movement on a reliable
request/response lane. Safari acquired Pointer Lock and moved Minecraft, but
disconnected on acknowledgement delays, including a 1.23-second idle response.
Measured device processing was 0-86 ms during one movement sample while some
round trips took roughly 700 ms. Raising the timeout and allowing two requests
in flight improved idle operation but did not qualify sustained movement.

Rootless13 separates lossy, unordered relative motion from reliable button/lease
control. Missing motion acknowledgements cannot stall input because that lane
does not acknowledge or retransmit. The reliable lane still owns button expiry;
motion alone never prolongs a held button. Both lanes must be negotiated before
the browser enables capture. The operator confirmed approximately 30 seconds of
normal Safari movement, then an `expired` error; clicks did not work.

Rootless14 addresses two source-level problems:

- Reliable control previously inherited motion's 100 ms queue deadline. It now
  gets 400 ms, still within the 500 ms IPC wait and 1500 ms lease. A single
  daemon-issued monotonic deadline covers both queues. Motion retains 100 ms;
  stale input is not retried and cannot revive a lost session.
- `IOHIDEventCreateMouseEvent` emitted only a mask, not button transitions. The
  relative-pointer constructor receives both current and previously emitted
  masks. Its button children are validated and numbered by changed bit: Apple's
  implementation can label multiple different transitions as button 1.
  A host test constructs all 1024 pairs of five-button states without dispatching
  input. See [Apple's event implementation](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDEvent.cpp)
  and [relative-pointer API usage](https://github.com/apple-oss-distributions/IOHIDFamily/blob/IOHIDFamily-1446.140.2/IOHIDFamilyUnitTests/TestMouseEventOptions.m).

Rootful and relay runtime remain unqualified.

Automated Chromium on this Mac rejected real Pointer Lock with
`WrongDocumentError` despite a focused document and active user gesture.
Manual Safari confirmation is therefore required for capture itself; transport
tests that inject deltas without Pointer Lock are not equivalent UI proof.

Rootless14 was built, public-package audited and installed with `install ok
installed`, followed by a SpringBoard restart; the LAN control page returned 200.
The full host suite, 33 protocol fixtures, 29 web tests, and rootful iOS 14
arm64/arm64e compilation passed. The web build and desktop/narrow-viewport menu
inspection passed for the unchanged rootless13 client. The 1024-transition event
construction test also passed on the actual iPadOS 15.5 device; its temporary
executable was removed afterward. This test does not dispatch input and is not
proof that Minecraft consumes the events. Rootless14 sustained Safari movement
and the button/scroll matrix remain pending operator confirmation; do not promote this
candidate as a qualified public release on build results alone.

Regression checklist:

1. Acquire through the real browser; move horizontally and vertically, including
   sustained movement past local screen edges. Confirm no simultaneous touches.
2. Test WASD plus mouse, left/right/middle clicks, and wheel direction.
3. Escape, blur, modal focus, hidden page, tab close and network loss must clear
   buttons; a new controller can acquire after release/expiry.
4. Verify duplicate sequence, wrong owner, malformed values, excessive queues
   and channel teardown. Do not accept stale movement after reconnect.
5. Verify ordinary touches and Text mode after exiting capture, with and without
   a physical keyboard/mouse. Repeat on rootful iOS 14 before claiming support.
6. Verify LAN and relay separately; do not describe compilation or HTTP/IPC
   acceptance as proof that a game received movement.

Host checks: `make test-game-pointer`, `(cd web && npm test && npm run build)`,
and `(cd protocol && npm test)`. Use `scripts/build-rootless.sh` for a candidate;
installation follows [`ROOTLESS.md`](ROOTLESS.md), not rootful deploy helpers.
