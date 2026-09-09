# RCTL Controller

`Controller` is the native iOS application for rctl devices. The Devices screen
supports saved local addresses without relay setup, alongside authenticated
relay pairing. Both paths share the native WebRTC implementation:

- scan or paste the relay admin's one-time controller pairing JSON;
- create and retain the P-256 controller identity in Keychain;
- renew sender-constrained refresh credentials and keep access credentials in
  memory only;
- list only approved devices through signed controller requests;
- open scoped screen or camera signaling over WSS;
- negotiate WebRTC, render decoded H.264 through Core Image/Metal, and report
  DataChannel state;
- render fixed-framebuffer video upright from the versioned state channel;
- map bounded multitouch through aspect-fit and orientation transforms;
- require an explicit `Control` mode before forwarding touches or system actions;
- present a responsive RCTL operator console with persistent source, safety-mode,
  Home, and session-tool controls;
- type bounded ASCII text and send Escape, Tab, Return, deletion, and arrow keys
  through the scoped control channel;
- send Home, lock, volume, Control Center, and Notification Center commands over
  the scoped control channel, with confirmation for device lock.

## Local Network

Choose **Add Local Device**, enter its private IP (port 8080 by default), and
optionally name it. Connect checks device capabilities, saves the address, and
opens video in View mode. Control requires an explicit mode change. Swipe or
long-press a saved device to edit or remove it; separate devices may share a port.

The public LAN-only `.deb` is sufficient. No VPS, domain, certificate setup,
controller identity, or relay enrollment is needed. The current unauthenticated
HTTP/WS device API is for trusted networks only. Relay credentials are never
sent to LAN; relay failures never automatically fall back to local control.
Only private IPv4 and bracketed IPv6 ULA literals are accepted in this slice;
hostname discovery and link-local IPv6 are not implemented. See
[`MOBILE-LAN.md`](../../../docs/MOBILE-LAN.md) for qualification limits.

Build from the repository root with `make mobile-ios-build`, or open
`RctlMobile.xcodeproj` and run the shared `RCTL Controller` scheme. Simulator
supports paste pairing and validates application lifecycle, but physical devices
are required to qualify QR capture, hardware decode, and network behavior.

Local app-level tests may launch a Debug build with
`RCTL_CONTROLLER_ALLOW_INSECURE_LOOPBACK=1` or the
`--rctl-allow-insecure-loopback` launch argument and pair only to an explicit
loopback HTTP relay origin. Release builds ignore both relay opt-ins and require
HTTPS for relay profiles. Explicit validated LAN connections are a separate path.

Before distributing the application, verify on a physical controller iPhone and
controlled iPad:

1. QR claim, process restart, Keychain restore, and refresh recovery.
2. Screen and camera H.264 rendering over direct ICE and TURN relay paths.
3. Expected scoped DataChannels and rejection of unavailable scopes.
4. Touch, paced text input, special keys, and mode gating in foreground apps.
5. Repeated connect, mode switch, background/foreground, and force-close cleanup.
6. At least 30 minutes of video with frame, thermal, memory, and reconnect data.

The current product slice does not yet implement Unicode clipboard input, audio
consumers, files, statistics export, or automatic reconnect policy. These are
tracked product increments; a successful build is not a release qualification.

## Lifecycle Regression Tests

`make mobile-ios-app-test` runs the shared scheme's `ControllerTests` target on
a temporary iOS 16+ simulator and deletes only that simulator afterward. Xcode,
Node.js, and an installed iOS simulator runtime are required. The script uses
ad-hoc simulator signing for Keychain; no Apple account or team is needed.
`make mobile-test` includes both package tests and these application tests.

The tests hold HTTP responses with `URLProtocol` and use isolated Keychain and
UserDefaults namespaces. They cover profile removal during refresh/device-list
requests, stale operation cleanup, shared concurrent refresh, terminal control
cleanup, and explicit control re-arming after transient disconnection. LAN tests
cover bounded capability reads, cancellation, address persistence/deduplication,
invalid saved data, and credential isolation; native screen attachments are kept
in the test results. By default no real relay or physical device is contacted.

Set `RCTL_LAN_TEST_ADDRESS` to an owned device's private address to opt into
real LAN video and suspend/resume testing (no touch or keyboard input).
`RCTL_IOS_TEST_RUNTIME=18.6 make mobile-ios-app-test` selects a specific installed
runtime; by default the newest iOS 16+ runtime is used. LAN video/reconnect have
passed on Simulator 18.6 and 26.1; physical iPhone permission behavior and the
full input/orientation matrix still need qualification.

Realtime package tests also exercise foreign PeerConnection callbacks through a
loopback WebSocket endpoint and invalidate already queued main-thread events.
Peer ownership checks happen on the transport queue; public start/stop invalidate
event delivery synchronously, and the app receives events directly on MainActor.
Refresh results are committed only to the profile generation that requested them.

Refresh keeps the sender-constrained secret stable while renewing its inactivity
expiry and replacing the access token. A process that dies before committing the
response to Keychain can safely repeat the operation with a fresh signed nonce.
