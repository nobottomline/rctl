# Native Mobile Controller Implementation Plan

Status: active. This plan turns `docs/MOBILE.md` into independently verifiable
delivery increments inside the rctl monorepo.

## Repository Decision

Keep the iOS and Android controller applications in this repository under
`mobile/`.

This is a protocol-coordination decision. Device runtime, relay, browser, iOS,
and Android must qualify against the same schemas, malformed-input corpus,
capability names, protocol version, and release fixtures. Splitting the mobile
clients now would add cross-repository version bumps and make contract drift
easier without creating an independent ownership or security boundary.

The monorepo does not imply one build or one release:

- the Theos package remains owned by the root device build;
- the relay remains a Go module and container/binary release;
- iOS is an Xcode application with local Swift packages;
- Android is a Gradle application with feature modules;
- each mobile store build has independent signing, versioning, CI, and release
  approval;
- `make package` never downloads or builds mobile dependencies;
- no app signing material, provisioning profile, keystore, relay origin, or
  controller credential is committed.

Reconsider a separate repository only if a distinct team needs independent
access control or release governance, the mobile SDK becomes a separately
versioned public product, or monorepo CI checkout/build cost becomes material.
If that happens, publish `protocol/` as immutable release artifacts and keep
cross-repository conformance tests mandatory.

## Native Stack

Native does not mean UIKit-only or Android Views-only.

- iOS uses Swift 6 and SwiftUI for application UI. Upstream WebRTC renderers,
  PiP surfaces, and other lifecycle-sensitive views are hosted through UIKit.
- Android uses Kotlin and Jetpack Compose for application UI. Upstream WebRTC
  renderers are hosted through `AndroidView` and platform media APIs.
- iOS starts with WebRTC's `RTCMTLVideoView`; it uses Metal through the upstream
  renderer. A custom Metal decoder/render graph requires measured evidence.
- Android starts with the upstream EGL renderer and hardware decoder. A custom
  Vulkan/OpenGL pipeline requires measured evidence.
- No Flutter, React Native, Kotlin Multiplatform, Compose Multiplatform, or Rust
  runtime is introduced in the first product cycle.

The iOS application uses a checked-in Xcode project and local Swift packages so
contributors need only Xcode. Android uses the checked-in Gradle wrapper. We do
not make Tuist, XcodeGen, CocoaPods, or a global Gradle install mandatory for
ordinary builds. Reproducible scripts own the pinned WebRTC XCFramework/AAR.

### iOS build-system decision

The canonical iOS build is Apple's Xcode build system:

- commit the `.xcodeproj`, shared schemes, test plans, asset catalogs, privacy
  manifest, and non-secret entitlements;
- keep project/target settings small and put reviewed settings in layered
  `Base.xcconfig`, `Debug.xcconfig`, and `Release.xcconfig` files;
- optionally include an ignored `Local.xcconfig` for a developer team or local
  experiment; release builds never depend on it;
- use local Swift packages for real compile boundaries, beginning with
  `RctlProtocol`; do not create one package per screen;
- pin remote Swift packages exactly and commit `Package.resolved` at the
  application level;
- wrap the checksum-verified WebRTC XCFramework in a local binary Swift package;
- use shared `xcodebuild` commands for local automation and CI, with signing
  disabled for compile/test jobs and isolated only in protected archive jobs.

Bazel is rejected for the first product cycle. Its additional Apple rules,
project integration, signing, cache infrastructure, and WebRTC build ownership
are not justified by one application and a small module graph. Tuist/XcodeGen
are also deferred: a generator would be another mandatory tool while the
checked-in project remains understandable and low-conflict.

Re-evaluate Tuist when the project has several applications/extensions, project
file conflicts become recurrent, or generated workspace policy removes measured
maintenance cost. Re-evaluate Bazel only if mobile builds become a large
multi-language graph whose clean-build time and remote-cache economics justify
owning a second Apple build system.

Design remains independent of this choice. SwiftUI previews and physical-device
previews use production components and fixture services; UIKit hosts WebRTC and
PiP surfaces; `Assets.xcassets` owns images/colors; semantic design tokens live
in Swift rather than a third-party theme framework. Snapshot and UI tests cover
stable component states, while interaction and media quality are qualified on
Simulator and physical devices.

## Monorepo Layout

```text
mobile/
  README.md
  ios/
    RctlMobile.xcodeproj/       # production host, added after the media spike
    App/
    Features/
    Platform/
    Realtime/
    Modules/
      RctlProtocol/             # native Swift wire models and validation
    Spikes/
      MediaProbe/               # non-shipping physical-device qualification app
  android/
    gradlew
    app/
    core/
    feature/
    realtime/
    spikes/
protocol/
  version.json                 # canonical protocol major/minor
  generate.mjs                 # deterministic generated constants
  schemas/
  datachannel/
  fixtures/
```

`protocol/` is data and contract source, not a cross-platform runtime. Generated
files contain constants/value types only and are checked for drift in CI.

## Work Rules

Each increment must be a complete, reviewable path with its own tests and
failure behavior. A screen that depends on an unimplemented fake service is not
a completed feature.

1. Change or add the wire contract and fixtures first.
2. Add relay/device support with authorization and resource limits.
3. Add native client support behind capability negotiation.
4. Exercise the real path on physical hardware when media, lifecycle, input, or
   secure storage is involved.
5. Record qualification evidence and only then expose the feature normally.

Protocol changes are additive within a major version. Unknown fields and
features are ignored; unknown enum/message variants fail locally and visibly.
Only a protocol-major mismatch refuses a connection.

## Phase 0: Contract Foundation

Deliverables:

- one canonical protocol version and deterministic language constants;
- schemas and size limits for capabilities, signaling, control, audio, and file
  DataChannels;
- golden valid, future-minor, unknown-feature, boundary, and malformed fixtures;
- state diagrams for signaling, connection generations, and file transfer;
- Swift, Kotlin, Go, and TypeScript conformance tests using the same fixtures;
- a documented compatibility and deprecation policy.

Exit criteria:

- generated-source drift fails CI;
- every current web message is inventoried;
- a newer minor fixture remains usable with unavailable features hidden;
- a different major is rejected before media or destructive actions start.

## Phase 1: Controller Identity

Add native-controller identities to the relay without weakening browser or
device authentication.

Deliverables:

- admin-created, single-use, short-lived QR pairing requests;
- P-256 controller key creation in Secure Enclave/Keychain and Android Keystore;
- proof-of-possession access and rotating refresh credentials;
- explicit scopes, controller list/rename/revoke, and bounded audit records;
- prompt active-session termination after revocation;
- recovery that never requires storing the relay admin password in the app.

Security tests cover replay, concurrent consumption, expiry, origin confusion,
key substitution, rotation races, scope escalation, log redaction, rate limits,
and database migration/rollback.

Exit criteria:

- losing one phone does not rotate an iPad `DeviceSecret`;
- revoking one controller does not affect other controllers;
- no credential appears in a URL, normal log, fixture, crash report, or backup;
- browser session behavior remains unchanged.

## Phase 2: Reproducible Media Dependencies

Pin one upstream WebRTC revision that interoperates with device-side
libdatachannel. Build an XCFramework and AAR from source in isolated scripts.
Pin libopus for custom audio DataChannels.

Every derived binary ships with source revision, patch list, build command,
checksum, license notices, SBOM, and vulnerability-update owner. Binary artifacts
are distributed through immutable release assets or a package registry, not
committed to Git.

Exit criteria:

- clean machines reproduce byte-identifiable inputs and verifiable outputs;
- simulator/device and Android ABI slices are explicit;
- H.264 hardware decode and custom DataChannels are present;
- license and symbol audits pass.

## Phase 3: Native Media Spikes

Build deliberately small iOS and Android probes before product navigation.

Required scenarios on physical phones:

1. Pair with a test relay and list devices.
2. Answer the device-created screen offer and render H.264 for 30 minutes.
3. Send touch and keyboard events with correct orientation mapping.
4. Decode app-audio and room-mic Opus channels.
5. Capture/encode Talk into `mic-in` without growing latency.
6. Open the separate camera PeerConnection.
7. Exercise direct, TURN/UDP, TURN/TCP, packet loss, Wi-Fi/cellular handoff,
   foreground/background, interruption, and reconnect.
8. Collect WebRTC stats, CPU, memory, thermal, battery, freezes, and queue depth.

The spike is successful only on the real iPad path. A local synthetic stream or
successful compilation is not qualification.

## Phase 4: iOS Vertical Product Slice

Build iOS first to keep product and protocol discovery serial and observable.

Initial slice:

- QR pairing and controller credential lifecycle;
- relay profiles and device list;
- immediate screen viewport, touch, keyboard, Home, orientation, and clipboard;
- app audio, room microphone, Talk route, quality, reconnect, and diagnostics;
- accessibility, permission denial, offline, incompatible, and revoked states.

Then add files, Photos, camera/recording, PiP, terminal, update, and destructive
system actions. Destructive actions display the full normalized target, request
the existing one-time confirmation token, and optionally require biometrics.

The application shell is SwiftUI. The remote video surface and PiP bridge are
UIKit-owned. Long-lived PeerConnections and audio engines belong to a session
coordinator, never SwiftUI view identity.

## Phase 5: Android Parity

Repeat the media gate with the same fixtures and acceptance scenarios, then
implement behavioral parity in Kotlin/Compose. Do not translate Swift types and
architecture line by line. Android owns foreground services, audio focus,
Keystore, back navigation, storage destinations, and PiP according to Android
lifecycle rules.

After both clients exist, measure duplicated platform-independent code. Extract
shared executable code only when a stable duplicated state machine is larger and
riskier than the additional runtime/FFI boundary.

## Phase 6: Qualification And Distribution

- synthetic demo relay/device mode for store review and deterministic UI tests;
- network conditioning and reconnect matrix;
- permission denial/revocation and background termination matrix;
- accessibility, Dynamic Type/font scale, screen reader, contrast, and reduced
  motion checks;
- lower-tier and current-device performance baselines;
- dependency provenance, SBOM, secret scan, and privacy manifest/disclosure;
- TestFlight and Play internal tracks before public review;
- independent signed mobile releases linked to a compatible protocol range.

Push notifications remain optional until a documented broker/trust model exists.
Self-hosted relays cannot silently depend on publisher-owned APNs credentials.

## Build And CI Boundaries

Root convenience commands orchestrate but do not merge toolchains:

```text
make protocol-check
make mobile-ios-test
make mobile-test
```

`mobile-android-test` joins `mobile-test` when the checked-in Gradle graph exists;
until then, no placeholder target reports a false pass.

CI jobs use path filters and independent caches. Device package, relay, web,
iOS, and Android failures remain attributable to their owning graph. Store
signing and release jobs are manual/protected and receive secrets only from the
platform secret store.

## Commit And Release Strategy

Work stays on the primary branch in coherent Conventional Commit increments:

- `feat(protocol): ...`
- `feat(relay): ...`
- `feat(ios): ...`
- `feat(android): ...`
- `test(mobile): ...`

Protocol changes and consumers may share one commit when atomicity prevents a
broken tree. App versions are independent from `.deb` and relay versions, while
release metadata declares the supported protocol major/minor range.

## Current Increment

The first implementation establishes:

- the `mobile/` ownership boundary;
- canonical protocol version consumption by C, Go, Vite, and Swift;
- capabilities fixtures;
- a native Swift protocol package with compatibility and validation tests;
- root/CI drift checks.

Controller authentication is the next increment. WebRTC application scaffolding
does not begin until that identity contract is reviewable.
