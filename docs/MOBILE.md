# Native Mobile Controller Architecture

Status: architecture in implementation. The iOS contract, identity, realtime
modules, and the first RCTL Controller product slice exist; Android and public
mobile distribution remain planned. This document does not describe a released
mobile binary.

## Decision

Build two native controller applications around one versioned wire contract:

| Surface | Primary stack | Platform media and integration |
|---|---|---|
| iOS | Swift 6, SwiftUI, structured concurrency | UIKit interop, upstream WebRTC Objective-C SDK, AVFoundation, AVKit, LocalAuthentication, Keychain, PhotosUI |
| Android | Kotlin, Jetpack Compose, coroutines/Flow | upstream WebRTC Android SDK, Android Views interop, AudioTrack/AudioRecord, PiP, Keystore, BiometricPrompt, Storage Access Framework |
| Browser | existing React/Vite client | browser WebRTC/WebCodecs; remains supported |
| Controlled iPad | existing Objective-C++/C++ runtime | libdatachannel remains inside `rctld` |
| Relay | existing Go service | auth, presence, signaling, TURN credentials, HTTP and stream tunnels |

Do not start with Flutter, React Native, Compose Multiplatform, Kotlin
Multiplatform, or a Rust shared runtime. Do not replace the working web client,
Go relay, or device-side libdatachannel transport.

This is a native-first decision, but not a license to hand-roll codecs, RTP,
congestion control, or cryptography. The controller applications should use a
pinned build of upstream libwebrtc. The old-iPad constraint that makes full
libwebrtc inappropriate inside the `.deb` does not apply to a modern App Store
or Play Store controller application.

## Why This Fits rctl

The hardest mobile screen is not a collection of forms. It is a long-lived,
latency-sensitive remote viewport surrounded by platform integration:

- hardware H.264 decode and presentation;
- high-rate multitouch, keyboard, pointer and orientation mapping;
- two independent screen/camera PeerConnections;
- custom Opus DataChannels for playback audio, room microphone and Talk;
- Picture in Picture and background audio lifecycle;
- native files, Photos, share sheets and resumable downloads;
- secure per-controller credentials and biometric authorization;
- reconnection across Wi-Fi/cellular transitions and app suspension.

SwiftUI and Compose are appropriate for navigation, device lists, settings,
files, media, terminal chrome and control surfaces. The realtime viewport is a
platform view hosted inside the declarative hierarchy. Apple supports UIKit
views through `UIViewRepresentable`; Android supports View components through
Compose `AndroidView`. This keeps libwebrtc's renderer and lifecycle out of the
normal declarative rendering loop without giving up native application UI.

A WebView wrapper is rejected as the product architecture. It would preserve
the mobile browser limitations that motivate this work, complicate native media
and background behavior, and risk App Store guideline 4.2 for repackaged web
experiences.

## Corrections To The Generic Shared-Core Proposal

The proposed model in which roughly 60 percent of the application immediately
moves into a Rust `rctl-core` does not match the current repository:

1. The realtime transport is already a standard WebRTC PeerConnection. A Rust
   networking runtime would either wrap libwebrtc through another FFI boundary
   or reimplement behavior that libwebrtc and the platforms already own.
2. The custom wire surface is small: signaling JSON, REST resources, six named
   DataChannels, compact control JSON, Opus frames and the file channel framing.
   It needs a contract and fixtures before it needs a runtime abstraction.
3. Reconnection, audio sessions, PiP, background execution, permission prompts,
   downloads and secure storage have different ownership on iOS and Android.
   Hiding them behind one abstraction would not make their failure modes equal.
4. A Rust core introduces a third mobile build system, two FFI layers, an async
   runtime boundary, cross-language cancellation and memory ownership before a
   second native implementation has proved what is actually duplicated.
5. Existing `core/` is device-runtime code shared by injected iOS components.
   It must not be repurposed as a controller SDK or made responsible for mobile
   application lifecycle.

Share contracts, fixtures and generated value types first. Extract executable
shared code only after both native clients contain the same stable, platform-
independent state machine and extraction measurably removes more complexity than
its FFI introduces.

If that threshold is reached, a future Rust library may contain pure codecs,
validation, checksums or deterministic protocol state. It must not own UI,
PeerConnection objects, platform audio sessions, secure storage, background
execution or OS permissions. Kotlin Multiplatform remains a valid later option
for repositories and value models, but adopting it before the Android client
exists would optimize an unmeasured duplication.

## Existing Contracts To Preserve

The mobile clients are new consumers of the current protocol, not a protocol
rewrite.

### Connection planes

- Native device discovery uses signed `GET /api/controller/devices`.
- Native screen signaling uses signed
  `/api/controller/devices/{id}/signal`.
- Native camera signaling adds the canonical `media=camera` query.
- Admin-browser control retains `/proxy`, `/stream`, `/term`, and `/signal`;
  scoped native equivalents are introduced per feature rather than reusing an
  admin cookie or exposing the relay administrator secret.
- Direct LAN signaling uses the device `/ws/signal` endpoint.
- `/v1/capabilities` gates optional features and protocol compatibility.

Only a protocol-major mismatch is fatal. Minor versions and feature differences
remain warnings or unavailable controls.

### WebRTC topology

`rctld` remains the offerer. It creates:

- one H.264 RTP track on the screen PeerConnection;
- a separate H.264 RTP track on the camera PeerConnection;
- reliable ordered `control`, `audio`, `room-mic`, `mic-in`, and `files`
  DataChannels on the screen PeerConnection;
- a reliable ordered `state` DataChannel on both screen and camera
  PeerConnections. Native controller scopes are authenticated by the relay and
  enforced again by `rctld`; browser-admin and local-LAN sessions preserve the
  existing full-trust channel set.

The legacy `files` channel is temporarily unavailable to scoped native sessions
because its daemon-side reply destination is process-global. Native file support
must first make transfer state and replies session-owned; failing closed avoids
cross-controller delivery while the native screen controller proceeds independently.

Do not combine screen and camera into one PeerConnection until the proven
device-side second-SSRC failure has been removed and physically qualified.

The controller should use libwebrtc's native jitter buffer, NACK/PLI handling,
H.264 depacketization, hardware decode and statistics. It should not initially
route RTP through FFmpeg, a custom jitter buffer, or a hand-written Metal/Vulkan
decoder. Metal or Vulkan is justified only by a measured rendering limitation.

### DataChannel formats

- `control`: UTF-8 JSON. Touch is `{t:"t",p,i,x,y}` and keyboard is
  `{t:"k",pg,u,d}`.
- `audio`: binary `[channels:1 byte][Opus packet]`, 48 kHz, 20 ms frames.
- `room-mic`: the same binary format, mono.
- `mic-in`: one raw Opus packet per binary message, mono 48 kHz.
- `files`: UTF-8 JSON control messages plus ordered binary chunks as documented
  in `web/src/lib/files.ts` and mirrored by `rctld`.
- `state`: versioned UTF-8 JSON device state. Version 1 carries the current
  `UIInterfaceOrientation` so fixed-portrait H.264 buffers render upright and
  input maps back to framebuffer coordinates without a privileged HTTP poll.

These formats currently rely on ordering and implicit message context. Before a
mobile release, assign each format an explicit schema version, maximum message
size, state diagram and golden malformed-input fixtures. Do not silently change
the existing version-1 bytes.

## Repository Layout

Add mobile clients without moving established directories:

```text
rctl/
  mobile/
    README.md
    ios/
      RctlMobile.xcodeproj
      App/
      Features/
      Platform/
      Realtime/
      Tests/
    android/
      app/
      core/
      feature/
      realtime/
  protocol/
    openapi/
    signaling/
    datachannel/
    fixtures/
    generated/
  web/                  # remains where it is
  relay/                # remains Go
  core/                 # remains device-runtime native code
```

`protocol/` is the source of truth. Generation should produce Swift, Kotlin and
TypeScript value types where it produces maintainable output. Hand-written
network clients remain thin and platform-native. Generated code is checked for
reproducibility and never contains relay origins, credentials or personal data.

## iOS Architecture

Use a SwiftUI application shell with feature modules and unidirectional state.
Keep long-lived connection objects outside view identity.

```text
RctlMobileApp
  AppModel
    RelayStore
    ControllerCredentialStore
    DeviceRepository
    SessionCoordinator
  Features
    Devices
    RemoteControl
    Files
    Photos
    Terminal
    Settings
  Realtime
    SignalingClient
    ScreenPeer
    CameraPeer
    AudioPipeline
    FileChannel
    InputMapper
  Platform
    KeychainIdentity
    BiometricGate
    RemoteVideoView
    PictureInPictureController
    BackgroundTransferStore
```

Keep transport and hardware decode in the upstream WebRTC Objective-C SDK. The
pinned SDK's Metal view accepted decoded frames without presenting them during
physical-device validation, so the controller uses a bounded Core Image/Metal
surface for decoded `CVPixelBuffer` presentation inside `UIViewRepresentable`.
PiP requires a dedicated renderer path compatible with `AVSampleBufferDisplayLayer` and
`AVPictureInPictureVideoCallViewController`; implement it after the base renderer
passes media qualification. Do not make a custom `MTKView` the default merely because
it is available.

Use `AVAudioEngine` or the appropriate AudioUnit path for Opus playback and
capture. The Talk path must preserve the current raw-input contract: do not
apply controller-side AEC, AGC or noise suppression by default because the
calling application on the iPad owns its voice-processing stage. Interruptions,
route changes, Bluetooth changes and phone calls must explicitly suspend or
rebuild the pipeline.

Store controller private keys and refresh credentials in Keychain. Sensitive
actions use LocalAuthentication at the point of use, not only at application
launch. Ordinary display names, relay metadata and cached capabilities may live
in a normal application database; secrets and media content may not.

### iOS visual system

The controller uses a small RCTL-owned visual layer instead of styling every
screen independently. Semantic colors, compact button treatments, interaction
states, haptics, and domain glyphs live beside the feature that owns them. The
remote viewport uses the same charcoal, amber, mint, and danger semantics as the
web operator console without copying browser layout into a native application.

Use native SwiftUI/UIKit behavior for navigation, menus, sheets, focus,
accessibility, Dynamic Type, and destructive confirmations. SF Symbols are the
default for standard Apple actions whose meaning users already know. RCTL-owned
glyphs or reviewed asset-catalog icons are appropriate for product-specific
concepts; an external icon or component package must have a pinned stable
release, an acceptable license, accessibility support, and clear maintenance
value. Appearance alone is not enough reason to add a runtime dependency.

The live viewport keeps only frequent actions in its persistent chrome. Source,
`View` / `Control`, Home, and session tools remain reachable at phone widths;
less frequent hardware actions use a scrollable sheet. Fixed viewport chrome
caps extreme text growth and substitutes labeled controls with accessible icons
when space is exhausted. Content sheets remain fully scalable and switch to a
single-column layout at accessibility sizes.

## Android Architecture

Use a single-activity Compose application with feature modules and
ViewModel/coroutine state. Host the libwebrtc renderer through `AndroidView` so
the media surface is not redrawn by Compose.

```text
Application
  RelayStore
  ControllerCredentialStore
  DeviceRepository
  SessionCoordinator
Features
  devices / control / files / photos / terminal / settings
Realtime
  signaling / screen / camera / audio / files / input
Platform
  keystore / biometric / pip / foreground-service / transfers
```

Use libwebrtc's platform renderer and hardware decoder first. Use AudioTrack and
AudioRecord for the custom Opus channels, with audio focus and explicit route
handling. Background playback or microphone use must be user-initiated and use
the correct foreground-service type and visible notification. The application
must never try to start microphone capture silently from the background.

Use Android Keystore for controller keys. Use the system Photo Picker, Storage
Access Framework and MediaStore instead of broad storage permissions. Support
PiP through the platform/Jetpack API and hide all controls that are not useful
inside the PiP window.

## Mobile Controller Authentication

The current relay browser cookie is appropriate for the admin website but is
not the final mobile credential model. A native app must not retain the relay's
master admin password or reuse an unrestricted browser session indefinitely.

Add a separate controller identity and session model:

1. An authenticated relay administrator creates a single-use controller pairing
   request, choosing a name, scopes and expiry.
2. Relay admin displays a QR code containing the HTTPS origin, request id,
   single-use secret, expiry, protocol major and relay identity fingerprint.
3. The app validates the origin and expiry, creates a non-exportable signing key
   in Secure Enclave/Keychain or Android Keystore, and submits its public key.
4. The relay consumes the pairing secret atomically and creates a controller
   record. Pairing secrets are stored hashed, expire within minutes and never
   appear in normal access URLs or logs.
5. The relay issues a hashed opaque refresh credential sender-constrained to the
   controller key. Access credentials are short lived. Refresh requires a fresh
   proof of possession, replaces outstanding access credentials, and renews the
   refresh credential's inactivity expiry without changing its secret.
6. Each controller can be listed, renamed and revoked independently. Revocation
   closes its signaling, terminal and stream sessions without rotating the iPad
   `DeviceSecret` or other controllers.

Suggested scopes are `screen.view`, `device.control`, `audio.listen`,
`microphone.talk`, `camera`, `files.read`, `files.write`, `terminal`,
`system.destructive`, `device.update` and `relay.admin`. The normal owner preset
may grant all device scopes, but relay administration remains separate.

Native HTTPS and WebSocket requests can carry an `Authorization` header. Do not
put access or refresh credentials in query strings. Continue to use Secure,
HttpOnly, SameSite cookies for browser sessions; controller auth is additive and
must not weaken the web path.

The relay is self-hosted, so the mobile application has no mandatory rctl cloud
account and does not require Sign in with Apple or Google. One app installation
may hold profiles for multiple independent relay origins and multiple
controllers per origin.

## Relay And Direct-LAN Modes

Relay mode is the primary mobile path even when the phone and iPad share Wi-Fi.
ICE can still choose a direct peer-to-peer route while the relay supplies auth,
signaling and TURN fallback. This avoids exposing the unauthenticated local API
to a mobile credential model.

Direct LAN remains an explicit recovery/offline profile:

- the user supplies or selects a local address;
- iOS declares and explains Local Network access;
- Android cleartext policy is restricted to the deliberate local profile;
- the UI identifies the profile as trusted-LAN control;
- no automatic broad subnet scan runs before user intent;
- relay and direct-LAN sessions never share credentials.

The current `:8080` API is intentionally unauthenticated on a trusted LAN. A
future authenticated local pairing protocol is desirable, but mobile work must
not quietly redefine that existing product contract. Relay-only mode continues
to make the local listener loopback-only.

## Media And Session Lifecycle

`SessionCoordinator` is the single owner of active mobile resources. Views issue
intent; they do not independently own PeerConnections, audio engines, camera
leases or background assertions.

- Foreground control may own screen, input and optional audio.
- PiP may retain screen video but never remote touch input.
- Background Listen may retain audio only after an explicit user action and only
  while the OS background mode permits it.
- Talk stops immediately when permission, audio focus, foreground eligibility or
  the user-held control is lost.
- Camera lease renewal stops when its view and recording are no longer active.
- Viewer loss closes both media sessions and releases device capture.
- Reconnection is generation-based; callbacks from an old generation cannot
  mutate a replacement session.
- Network changes trigger ICE recovery or a bounded reconnect, not parallel
  unbounded PeerConnections.

Every queue is bounded. Video prefers the newest decodable frame. Audio drops
stale backlog rather than increasing latency. File transfer has explicit
backpressure, cancellation and integrity state. Application suspension must not
leave camera, microphones, recordings or iPad power assertions active.

## Files, Photos And Terminal

Large downloads continue through the authenticated HTTP stream tunnel directly
to a platform file destination. Do not assemble them in RAM. Bounded previews,
share preparation and current uploads may use the `files` DataChannel.

Before claiming resumable transfer, add a version-2 file protocol with transfer
ids, offsets, expected length, content hash, cancellation and expiry. HTTP range
support or an equivalent server-side resume contract is required for interrupted
large downloads; local UI persistence alone is not resume.

Photos should consume the existing opaque media ids and preview endpoints.
Native apps gain platform share/save UI but do not receive filesystem paths or
write Photos.sqlite. Confirmed deletion keeps the existing one-time token and
PhotoKit transaction on the controlled device.

Use an established terminal emulator component after a license, maintenance and
malformed-sequence review. A terminal is not a styled text view. Keep the PTY
WebSocket protocol unchanged and require biometric confirmation before opening
an unrestricted root terminal when the user enables that policy.

## Product UI

The mobile first screen is the device list, not a marketing page. Selecting an
online device opens the remote viewport immediately. The viewport owns the first
screen; secondary controls use compact native sheets, menus and toolbars.

Primary mobile controls:

- reconnect and connection-path status;
- keyboard, clipboard, Home and orientation;
- app audio, iPad output, room microphone and Talk route;
- camera front/back and recording;
- files and Photos;
- terminal and advanced system actions;
- quality presets and diagnostics.

Do not expose every daemon endpoint as an equal button. Frequent actions remain
one gesture away; dangerous and rare actions live in an advanced surface with
full target text, confirmation token and optional biometric gate.

Share design tokens such as semantic colors, spacing, icon names and motion
durations as data, not cross-platform UI code. Each platform applies its native
typography, accessibility, safe-area, keyboard and navigation behavior. Custom
visual components are justified by the remote-control workflow, not by a desire
to hide standard system controls.

## Performance Contract

Measure the real path on physical devices. Framework choice is not accepted as
proof of performance.

- Input mapping and enqueue should complete within one display frame at p95.
- No controller-owned video queue may retain more than the minimum required for
  decode; stale video must not grow behind network delay.
- Audio playout targets a small bounded jitter window and must recover after
  route changes without reconnecting the entire screen session.
- A reachable session should reconnect automatically after Wi-Fi/cellular
  handoff; failure remains visible and cancellable.
- Screen and camera statistics report ICE candidate type, RTT, jitter, frames
  decoded/dropped, freeze count and bitrate without media content or secrets.
- CPU, thermal state, battery and memory are acceptance metrics on both a lower-
  tier supported phone and a current high-refresh phone.

Automatic encoder adaptation is not initially owned by each controller. The
iPad currently has a shared encoder; competing viewers changing quality would
fight. Start with explicit presets and diagnostics. A later daemon-owned policy
may aggregate receiver feedback and choose one encoder profile for all viewers.

## Dependency Policy

The preferred media dependency is a pinned upstream WebRTC commit built into an
XCFramework and AAR by reproducible CI scripts. Publish checksums, provenance,
licenses and an SBOM for those derived binaries. Do not depend on an unversioned
tip-of-tree package or commit opaque third-party binaries without provenance.

Use a pinned upstream libopus build for the custom audio channels. FFmpeg is not
part of the realtime path. Add it only for a concrete container/codec operation
that AVFoundation, MediaMuxer or a smaller audited demuxer cannot perform, and
only after size, license and security-update ownership are accepted.

Every additional UI, terminal, image or networking library requires:

- active maintenance and a pinned immutable version;
- compatible license and complete notices;
- no bundled analytics or undisclosed network traffic;
- supply-chain provenance and vulnerability monitoring;
- a demonstrated reduction in code or risk.

## App Store And Play Distribution

The application is a controller for a user-owned remote device. It does not
install a jailbreak, download executable features, execute remote code on the
phone, or bypass the controller phone's sandbox. Store metadata and review notes
must describe its actual behavior; advanced features must not be hidden from
review.

Provide App Review with a stable demo relay and a fully usable synthetic device
mode so reviewers do not need a jailbroken iPad. The demo exercises navigation,
screen playback, gestures, files, Photos, terminal presentation and permission
explanations without granting access to production infrastructure.

Microphone, Photos, local-network and notification permissions are requested at
the feature that needs them, with a useful denial path. Background audio and
Android foreground services exist only for an active user-visible session.
Privacy disclosures cover data that transits the self-hosted relay even when the
project operator cannot read or retain it.

Push notification delivery is not an MVP promise. APNs credentials belong to
the app publisher, so arbitrary self-hosted relays cannot independently send
APNs notifications under the app's topic. A future push feature needs an
explicit optional project-operated broker or another clearly documented trust
model; it must not quietly turn a self-hosted product into a mandatory cloud
service.

## Delivery Plan

### Phase 0: contract and security foundation

1. Inventory every REST, signaling and DataChannel message used by `web/`.
2. Add versioned schemas, size limits, state diagrams and golden fixtures.
3. Implement controller pairing, scoped credentials, recoverable refresh,
   revocation and audit events in the relay.
4. Add a synthetic device/relay test harness that contains no personal data.

### Phase 1: media qualification

Qualify the native iOS and Android media implementations before broadening the
production navigation:

1. Pair and authenticate to a test relay.
2. Answer the device-created screen offer and render H.264 for 30 minutes.
3. Send touch/key control and verify orientation mapping.
4. Decode both Opus listening channels and encode `mic-in` Talk.
5. Exercise forced TURN UDP/TCP, packet loss, network handoff and reconnect.
6. Prove iOS and Android PiP/background lifecycle on physical devices.

Do not commit to a binary WebRTC distribution until this spike passes with a
pinned upstream revision on both platforms.

### Phase 2: iOS vertical product slice

Ship internally with pairing, device list, screen, touch, keyboard, clipboard,
quality, app audio, Talk, reconnect, diagnostics and credential revocation.
Then add files, Photos, camera, recording, PiP, terminal and destructive actions.

### Phase 3: Android parity

Implement the same contract with native Android ownership. Do not port Swift
architecture line-for-line; match behavior and acceptance tests. Extract shared
runtime code only after measured duplication justifies it.

### Phase 4: store qualification

Run TestFlight and Play internal testing, privacy review, permission denial,
background lifecycle, accessibility, network conditioning, lower-tier device
performance and demo-review qualification before public submission.

## Go/No-Go Gates

Do not call the mobile architecture validated until all of these pass:

- screen and camera H.264 decode on supported physical iOS and Android devices;
- control stays responsive during video loss and large transfers;
- app audio, room microphone and Talk do not accumulate unbounded latency;
- screen/camera recover after app backgrounding and network transitions;
- relay session revocation terminates active native connections promptly;
- losing one phone does not require rotating an iPad device secret;
- direct LAN remains available when relay is unavailable and explicitly chosen;
- closing every viewer releases device capture and power assertions;
- store demo mode reveals the real product without production credentials;
- all third-party binaries have reproducible provenance, licenses and SBOMs.

## References

- Apple UIKit integration with SwiftUI:
  <https://developer.apple.com/documentation/SwiftUI/UIKit-integration>
- Apple Picture in Picture for video calls:
  <https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-for-video-calls>
- Apple Keychain Services:
  <https://developer.apple.com/documentation/security/keychain-services>
- Apple local-network privacy:
  <https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy>
- Apple App Review Guidelines:
  <https://developer.apple.com/app-store/review/guidelines/>
- Upstream WebRTC iOS SDK/build documentation:
  <https://webrtc.googlesource.com/src/+/main/docs/native-code/ios/README.md>
- Upstream WebRTC Objective-C SDK:
  <https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/>
- Upstream WebRTC Android SDK:
  <https://webrtc.googlesource.com/src/+/main/sdk/android/README>
- Android Compose/View interoperability:
  <https://developer.android.com/develop/ui/compose/migrate/interoperability-apis/views-in-compose>
- Android Picture in Picture:
  <https://developer.android.com/develop/ui/views/picture-in-picture>
- Android foreground-service types:
  <https://developer.android.com/develop/background-work/services/fgs/service-types>
- Android Keystore:
  <https://developer.android.com/privacy-and-security/keystore>
- Kotlin Multiplatform code-sharing model:
  <https://kotlinlang.org/docs/multiplatform/multiplatform-share-on-platforms.html>
