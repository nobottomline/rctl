# Changelog

Version headings may describe unpublished candidates. Release availability is
determined by GitHub Releases, not by the presence of a changelog entry.

## Unreleased

- Added signed server-release discovery and a managed update supervisor, with
  admin-page installation, persistent job results, and opt-in scheduled relay
  updates. Device installation remains separately confirmed.
- Reject device update downgrades using Debian version ordering, including
  rootless qualification versions and package revisions.

## 0.4.1

Supersedes the unpublished `0.4.0` candidate and includes its changes below.
The earlier draft and tag are retained unchanged.

- Reduced screen and camera RTP fragment sizes to reserve space for IPv6,
  SRTP, and TURN overhead instead of relying on IP fragmentation.
- Always rebuild the device control client during packaging, so version or
  configuration changes cannot leave stale HTML in either package variant.
  A failed web build stops packaging rather than reusing an older client.
- Added release-build checks for video packet sizing, authorization ownership,
  and Talk playback recovery. Experimental video pacing was withdrawn and is
  not included in this candidate.

## 0.4.0

Changes since the last published release, `0.3.2`, including the unpublished
`0.3.3` and `0.3.4` work recorded below.

### Device and Web Control

- Added ordinary Dopamine rootless packages alongside rootful builds, with
  separate `iphoneos-arm64` / `iphoneos-arm` artifacts and a shared version.
- Added Game Keyboard for held keys and WASD, plus Capture Mouse for relative
  movement, clicks, and wheel input. Ownership leases release input on session
  loss; mouse movement uses a separate, bounded WebRTC channel.
- Added real device orientation locking and automatic rotation through the
  console and API, independently of the browser's visual rotation setting.
- Added pause/resume during recorded-input playback and JSON script export.
  Invalid or unsupported script actions are rejected instead of silently skipped.
- Added screenshot preview with a separate save action, device volume display,
  and custom alerts without a forced title. Renamed Photos to Media.
- Added Bonjour LAN discovery and an explicit `LAN + Relay` / `Relay only`
  access policy. Installing relay configuration alone does not disable LAN.
- Added signed APT repository publishing for Cydia, Sileo, Zebra, and Installer,
  with architecture-specific admission and release qualification gates.

### Relay and Updates

- Extended the setup wizard to provision both public package variants through
  install, upgrade, backup, restore, and recovery. Relay admin can now generate
  personalized rootless packages as well as rootful ones.
- Added architecture-bound rootless device updates with verified rollback,
  preserving relay identities and LAN policy. Rootless packages cannot be
  replaced by a rootful update catalog.
- Added visible wizard stages and timing, bounded TLS failure diagnostics, and
  preservation of recovery state when rollback cannot safely stop services.
- Added controller permissions, presence, device profiles, connection history,
  and attributed audit events. Large admin lists are virtualized, with view
  switches kept reachable outside scrolling content.
- Bound controller pairing to the relay identity and HTTPS origin. Permission
  edits invalidate stale sessions; authorization leases and transport-loss
  cleanup prevent disconnected controllers from retaining an unchecked session.

### Fixes

- Corrected sideways capture and touch geometry on the 12.9-inch rootless iPad
  Pro by normalizing the native panel before encoding.
- Fixed duplicate passcode digits and stuck keyboard modifiers after browser
  focus loss, and corrected inverted trackpad scrolling during mouse capture.
- Fixed rootless video posters, microphone recording startup, and repeated Talk
  speaker playback. Browser Talk sessions now report microphone failures and
  ignore stale callbacks from an earlier session.
- Hardened Listen capture against invalid PCM layouts, short buffers, and stale
  samples in silent renders; sustained intermittent-noise testing remains open.
- Fixed literal shell prompt escapes in the rootless terminal and duplicate
  tweak entries caused by scanning symlinked injection directories twice.
- Replaced shifting hover styles with scoped feedback, used the shared
  orientation dropdown, added copied-state icons, and removed the doubled
  battery percent sign.
- Hid image-copy and file-sharing actions when browser security requirements
  are unmet; Download remains available on local HTTP.
- Fixed TURN relay-address selection and valid zero-valued ICE role attributes
  being rejected, which blocked browser TURN/TCP connections to the device.
- Fixed stale relay-admin assets in builds and updated vulnerable dependencies.

### Native iOS Controller (In Development)

- Added a native controller with multiple relay profiles, QR pairing, LAN
  discovery, access-path indicators, multitouch, keyboard input, and media tools.
- Added orientation-aware video/input, session recovery with fresh-video input
  gating, bounded responses, and camera leases that stop capture on viewer loss.

RootHide is outside this rootless target. Native device TURN remains UDP-only;
browser Talk, image copy, and sharing still require a supported secure context.
See [release readiness](docs/ROOTLESS-RELEASE.md) for the remaining acceptance
checks; these changes do not imply that final release qualification is complete.

## 0.3.4

- Added the native mobile-controller protocol, QR pairing flow, proof-of-possession
  identities, least-privilege media scopes, and recoverable controller sessions.
- Added the iOS MediaProbe qualification app with native device discovery,
  WebRTC signaling, H.264 rendering, and bounded control DataChannels.
- Formalized versioned JSON wire contracts shared by relay, browser, and native
  clients, including forward-compatible capability validation.

## 0.3.3

- Added an administrator-controlled `LAN + Relay` / `Relay only` network policy.
  Relay-only mode binds the device API to loopback, requires an approved relay
  identity, uses confirmation-token mutations, and includes an SSH recovery path.
- Replaced opaque setup pauses with numbered, color-aware lifecycle progress,
  per-stage timing, terminal spinners, plain CI logs, and signal-aware
  cancellation that preserves rollback behavior.
- Reworked the project README around the verified one-command VPS setup and the
  public LAN-only package flow.

## 0.3.2

- Fixed interactive `curl | sudo sh` setup by reconnecting the verified wizard
  to the controlling terminal and added visible lifecycle progress.
- Added a release-gated, P-256 signed stable device-update catalog with exact
  target and rollback package verification.
- Added update target awareness so already-current devices are not offered a
  redundant transaction.
- Documented the intentional unauthenticated trusted-LAN/USB local-control
  contract and added contributor navigation across runtime components.
- Made release-signing key permission validation portable across GNU/Linux and
  BSD/macOS `stat` implementations.

## 0.3.0

- First qualified public package and self-hosted relay release.
