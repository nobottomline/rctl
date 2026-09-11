# RCTL Controller

`Controller` is the native iOS application for rctl devices, shown to users as
`rctl`. The Devices screen supports saved local addresses without relay setup,
alongside authenticated relay pairing. Both paths share the native WebRTC
implementation:

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

## Connection Reliability

The shared LAN/Relay session has a bounded recovery policy, not an always-on
background connection:

- Transient failures retry at most three times, after 1, 2, and 4 seconds. Each
  attempt repeats the capabilities/authentication preparation and replaces the
  old peer. The budget resets only on an explicit new connection or foreground
  resume, not on a brief successful connection. Certificate/authentication
  failures during HTTP preparation, protocol rejection, and input congestion
  do not trigger this recovery loop. Transport signaling failures use the same
  bounded budget and must pass HTTP preparation again before opening a socket.
- Every connection, interruption, suspension, and recovery returns to **View**.
  Re-entering **Control** always requires an explicit action.
- A decoded-frame observer samples frame arrival at most every 250 ms; a
  500 ms watchdog marks video stale after 3 seconds without frames and disables
  control. After 15 seconds without frames the peer fails and can reconnect.
  Frame time, session generation, and track identity are checked; a delayed
  first-frame notification alone cannot authorize input. This detects decoder
  progress, not proof that the GPU presented the frame.
- Sent touches and held keys are tracked by the transport. Leaving Control
  cancels queued input and sends their releases independently of the UI mode.
  Release delivery is best effort when the channel has already failed; it is
  not a guarantee of remote cleanup after network loss or process termination.
- Keyboard batches are admitted atomically, with a 10.5-second total scheduling
  window. The shared input queue permits at most 1,024 messages / 64 KiB, has
  one timer and coalesced drain work, and invalidates old queued generations.
  WebRTC's buffered bytes are limited to 64 KiB. Only intermediate touch moves
  may be dropped under backpressure; failure to send other input ends control
  visibly instead of silently losing a press or release.
- Session Controls displays per-second decoded FPS, video bitrate, interval
  packet loss, ICE RTT, and the selected Direct/TURN media route. Unavailable
  metrics remain unknown, not zero. The route is separate from LAN/Relay access:
  relay signaling can still negotiate direct media.
- Relay JSON reads enforce the 1 MiB bound while receiving, including error
  bodies. Declared oversize responses and redirects are rejected, cancellation
  aborts the task, and a 20-second total deadline bounds slow responses.

Closed and failed sessions show an explicit end/reconnect state, not an endless
loading indicator. Physical network handoff, forced TURN, long-running camera
sessions, and release delivery during an active gesture remain release gates.

## Devices And Pairing

Devices is the root of one `NavigationStack`; pairing, the scanner, the
local-device editor, and control are pushes with working back navigation. The
screen uses the warm parchment theme and ambient particle canvas described in
`docs/MOBILE-DESIGN.md`; the stack root selects light or dark presentation from
the current route. Saved local devices show a best-effort reachability chip
from the bounded capabilities probe, or `Discovered` while their exact address
is advertised; relay devices show online, update, and compatibility state, and
an unavailable relay device explains why when tapped.

`Nearby` renders the opt-in discovery flow with explicit searching, empty,
permission-denied, unavailable, resolving, and checking states, and keeps
`Add by address` and `Stop` reachable in every state. Selecting a device
re-resolves it, then a decision sheet offers `Open in View mode`, `Save
device`, or a confirmed address replacement for a saved entry; the editor's
`Update address` mode shows the current and found addresses before anything
changes. LAN/Relay stays visible in the session header and Session Controls.

Pairing opens an intro with the three relay-admin steps, then a full-screen
scanner whose reticle follows the detected code, confirms a lock-on, and claims
the code in place. Non-pairing QR codes are rejected locally, a failed claim
ignores the same payload briefly, and paste plus torch are always available.

The Relay menu supports **Add relay** and switching between saved servers,
with a checkmark on the selected server. There is no fixed saved-relay count
limit. Each server keeps its own Keychain identity; device lists and volatile
tokens belong to the selected profile only. Removing one profile preserves the
others. **Revoke access** first revokes the selected controller on its relay and
removes local credentials only after confirmation. **Forget locally** removes
only the saved profile and keys, including offline; it does not revoke access
on the server. Failed or ambiguous revocation preserves the profile and shows
an error. Already-forgotten controllers must be revoked from relay admin.

The selected relay receives a signed heartbeat every 30 seconds while the app
is active, including during a remote session. Backgrounding or switching relays
lets the old 90-second lease expire. Admin shows authorization separately from
Online/Offline and open signaling sessions. Legacy clients without heartbeats
have unknown presence. See [controller lifecycle](../../../protocol/controller-lifecycle-v1.md).

The original single-profile store migrates automatically. Re-pairing
an already saved relay is rejected before making a claim; select its profile
instead. A session cannot reconnect through a different selected relay.

Debug builds accept `--rctl-route=pair|scan|local|save|replace|first-local|
gallery|gallery2` to open a screen directly for screenshots and review;
`gallery` and `gallery2` render the discovery and session building blocks with
synthetic data. Release builds ignore the argument.

## Local Network

Choose **Add local device**, enter its private IP (port 8080 by default), and
optionally name it. Connect checks device capabilities, saves the address, and
opens video in View mode. Control requires an explicit mode change. Long-press a
saved device to edit or remove it; separate devices may share a port.

The public LAN-only `.deb` is sufficient. No VPS, domain, certificate setup,
controller identity, or relay enrollment is needed. The current unauthenticated
HTTP/WS device API is for trusted networks only. Relay credentials are never
sent to LAN; relay failures never automatically fall back to local control.
Manual entry accepts only private IPv4 and bracketed IPv6 ULA literals; Bonjour
resolves and validates private IPv4 before connecting. Link-local IPv6 is not
implemented. See
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
consumers, files, or statistics export. These are
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
cleanup, fresh-frame control gating, the three-attempt recovery budget, retry
cancellation on background, and explicit control re-arming after interruption. LAN tests
cover bounded capability reads, cancellation, address persistence/deduplication,
invalid saved data, and credential isolation; native screen attachments are kept
in the test results. By default no real relay or physical device is contacted.

Set `RCTL_LAN_TEST_ADDRESS` to an owned device's private address to opt into
real LAN video, live Direct-route diagnostics, and suspend/resume testing
(no touch or keyboard input).
`RCTL_IOS_TEST_RUNTIME=18.6 make mobile-ios-app-test` selects a specific installed
runtime; by default the newest iOS 16+ runtime is used. LAN video/reconnect have
passed on Simulator 18.6 and 26.1; physical iPhone permission behavior and the
full input/orientation matrix still need qualification.

Realtime package tests also exercise foreign PeerConnection callbacks through a
loopback WebSocket endpoint and invalidate already queued main-thread events.
Pure-state regressions cover input admission, ordered release generation,
cancelled keyboard batches, frame freshness, and statistics counter resets.
Client tests cover exact/oversized/unknown-length/error responses and cancellation;
a real loopback HTTP server verifies header rejection and redirect refusal
after only one body byte, without waiting for the advertised body to complete.
Peer ownership checks happen on the transport queue; public start/stop invalidate
event delivery synchronously, and the app receives events directly on MainActor.
Refresh results are committed only to the profile generation that requested them.

Refresh keeps the sender-constrained secret stable while renewing its inactivity
expiry and replacing the access token. A process that dies before committing the
response to Keychain can safely repeat the operation with a fresh signed nonce.
