# RCTL Controller

`Controller` is the native iOS application for managing approved rctl devices.
The current product slice uses the same authenticated relay and WebRTC paths as
the browser client:

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

Build from the repository root with `make mobile-ios-build`, or open
`RctlMobile.xcodeproj` and run the shared `RCTL Controller` scheme. Simulator
supports paste pairing and validates application lifecycle, but physical devices
are required to qualify QR capture, hardware decode, and network behavior.

Local app-level tests may launch a Debug build with
`RCTL_CONTROLLER_ALLOW_INSECURE_LOOPBACK=1` or the
`--rctl-allow-insecure-loopback` launch argument and pair only to an explicit
loopback HTTP origin. Release builds ignore both opt-ins and require HTTPS.

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

Refresh keeps the sender-constrained secret stable while renewing its inactivity
expiry and replacing the access token. A process that dies before committing the
response to Keychain can safely repeat the operation with a fresh signed nonce.
