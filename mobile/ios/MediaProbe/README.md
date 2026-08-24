# RCTL MediaProbe

`MediaProbe` is a non-shipping iOS host for qualifying the native controller
path against a real relay and controlled iPad. It is deliberately small but it
uses production boundaries rather than fake services:

- scan or paste the relay admin's one-time controller pairing JSON;
- create and retain the P-256 controller identity in Keychain;
- renew sender-constrained refresh credentials and keep access credentials in
  memory only;
- list only approved devices through signed controller requests;
- open scoped screen or camera signaling over WSS;
- negotiate WebRTC, render H.264 through the vendor Metal view, and report
  DataChannel state;
- send the Home HID command when the scoped control channel is open.

Build from the repository root with `make mobile-ios-build`, or open
`RctlMobile.xcodeproj` and run the shared `RCTL MediaProbe` scheme. Simulator
supports paste pairing and validates application lifecycle, but has no camera
for QR capture and cannot qualify hardware decode or network behavior.

Local app-level tests may launch a Debug build with
`RCTL_MEDIAPROBE_ALLOW_INSECURE_LOOPBACK=1` or the
`--rctl-allow-insecure-loopback` launch argument and pair only to an explicit
loopback HTTP origin. Release builds ignore both opt-ins and require HTTPS.

Before promoting the WebRTC dependency or starting the production UI, verify on
a physical controller iPhone and controlled iPad:

1. QR claim, process restart, Keychain restore, and refresh recovery.
2. Screen and camera H.264 rendering over direct ICE and TURN relay paths.
3. Expected scoped DataChannels and rejection of unavailable scopes.
4. Repeated connect, mode switch, background/foreground, and force-close cleanup.
5. At least 30 minutes of video with frame, thermal, memory, and reconnect data.

The probe does not yet implement coordinate input, audio consumers, files,
statistics export, or production reconnect policy. Those remain product
increments and must not be inferred from a successful probe build.

Refresh keeps the sender-constrained secret stable while renewing its inactivity
expiry and replacing the access token. A process that dies before committing the
response to Keychain can safely repeat the operation with a fresh signed nonce.
