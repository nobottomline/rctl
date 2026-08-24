# RCTL MediaProbe

`MediaProbe` is a non-shipping iOS host for qualifying the native controller
path against a real relay and controlled iPad. It is deliberately small but it
uses production boundaries rather than fake services:

- scan or paste the relay admin's one-time controller pairing JSON;
- create and retain the P-256 controller identity in Keychain;
- rotate refresh credentials and keep access credentials in memory only;
- list only approved devices through signed controller requests;
- open scoped screen or camera signaling over WSS;
- negotiate WebRTC, render H.264 through the vendor Metal view, and report
  DataChannel state;
- send the Home HID command when the scoped control channel is open.

Build from the repository root with `make mobile-ios-build`, or open
`RctlMobile.xcodeproj` and run the shared `RCTL MediaProbe` scheme. Simulator
supports paste pairing and validates application lifecycle, but has no camera
for QR capture and cannot qualify hardware decode or network behavior.

Before promoting the WebRTC dependency or starting the production UI, verify on
a physical controller iPhone and controlled iPad:

1. QR claim, process restart, Keychain restore, and refresh rotation.
2. Screen and camera H.264 rendering over direct ICE and TURN relay paths.
3. Expected scoped DataChannels and rejection of unavailable scopes.
4. Repeated connect, mode switch, background/foreground, and force-close cleanup.
5. At least 30 minutes of video with frame, thermal, memory, and reconnect data.

The probe does not yet implement coordinate input, audio consumers, files,
statistics export, or production reconnect policy. Those remain product
increments and must not be inferred from a successful probe build.

Refresh tokens rotate in a single relay transaction. Terminating the app in the
small interval after relay commit but before the replacement credential reaches
Keychain can require pairing the controller again. The production client must
not ship until the refresh protocol has a tested recovery mechanism for this
process-death case.
