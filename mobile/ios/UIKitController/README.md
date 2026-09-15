# rctl UIKit controller

A native UIKit rewrite of the iOS controller (`../Controller`, SwiftUI) built
for responsiveness on every supported device, from iOS 13 phones to current
iPads. It consumes the same local packages (`../Modules`: RctlProtocol,
RctlClient, RctlRealtime) and keeps the SwiftUI app's product behavior,
security properties and lifecycle invariants; the UI is redesigned.

| | |
|---|---|
| Project / scheme | `RctlUIKit.xcodeproj` / `RctlUIKit` (tests: `RctlUIKitTests`) |
| Bundle ID | `com.greatlove.rctl.controller.uikit` (installs next to the SwiftUI app) |
| Display name | `rctl` |
| Deployment target | iOS 13.0, iPhone + iPad, Swift 6, strict concurrency, warnings as errors |
| Dependencies | Local packages only. No third-party UI frameworks (launch time, binary size). |
| Icons | Lucide (same set as the web client), generated to native paths: `Tools/icons` |

Signing is machine-local: Debug/Release include the git-ignored
`../Config/Local.xcconfig` (`DEVELOPMENT_TEAM`). Never commit a team ID.

## Build and test

```sh
# Simulator build (no signing)
xcodebuild -project RctlUIKit.xcodeproj -scheme RctlUIKit -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO build

# Unit + lifecycle tests on a disposable simulator (ad-hoc signing for Keychain)
xcodebuild -project RctlUIKit.xcodeproj -scheme RctlUIKit -configuration Debug \
  -destination "platform=iOS Simulator,id=<udid>" -derivedDataPath .derivedData \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test
```

Create and delete your own simulator for tests (`xcrun simctl create …`);
never reuse or erase a personal one. The WebRTC binary package is resolved
into `.derivedData/SourcePackages`; seed it from another checkout with an APFS
clone (`cp -cR`) instead of downloading it again.

Debug launch arguments (Release ignores them), handled in
`App/Application/DebugLaunch.swift`:

- `--rctl-route=pair|scan|local|edit|save|replace|first-local|remote|gallery`
- `--rctl-push=local|pair` — animated push 1.5 s after launch with a black marker (latency measurement)
- `--rctl-appearance=system|warm|console`
- `--rctl-demo` — screens that support it render synthetic fixtures (no network, no stored data)
- `--rctl-scanner-demo` — scripted QR detections in the scanner
- `--rctl-scanner-state=denied|unavailable`, `--rctl-pairing-action=paste|claim-invalid` — camera-less scanner states and pairing actions without network
- `--rctl-editor-error` / `--rctl-editor-pending` — local device editor error and checking states without network
- `--rctl-remote-demo=connecting|live|control|camera|failed|reconnecting|stalled|ended|keyboard|tools|lock|source-menu|missing|cycle` with `--rctl-route=remote` (`--rctl-remote-demo-path=relay`, `--rctl-remote-demo-orientation=landscape`) — remote session states without a connection
- `--rctl-demo=first-run|nearby-denied|nearby-searching|nearby-empty|relay-loading`, `--rctl-demo-menu=<menu or dialog>`, `--rctl-demo-sheet`, `--rctl-demo-cycle`, `--rctl-scroll=<pt>` — Devices screen fixtures, menus and states
- `--rctl-allow-insecure-loopback` / `RCTL_CONTROLLER_ALLOW_INSECURE_LOOPBACK=1` — loopback HTTP relay for tests

## Architecture

```
App/
  Application/   AppDelegate, SceneDelegate, AppEnvironment, AppRouter, RCNavigationController, DebugLaunch
  Core/          Domain models ported from the SwiftUI app (auth, presence, LAN, sessions)
  DesignSystem/
    Tokens/      RCColor, RCTypography, RCSpace/RCRadius/RCLayout, RCMotion, RCShadow, RCHaptics, RCAppearance
    Foundation/  RCView/RCControl base classes, RCLabel, RenderScheduler
    Icons/       RCIconGlyph (generated), RCIcon, RCIconView
    Components/  Buttons, indicators, surfaces, lists, inputs, chrome (top bar, ambient, refresh)
    Overlays/    RCMenu, RCContextMenuInteraction, RCSheet, RCDialog, RCToast
  Features/      Devices, Pairing, LocalDevice, Remote, Gallery (DEBUG)
  Resources/     Info.plist, assets, launch screen, privacy manifest
Tests/           XCTest target (hosted)
```

The project uses Xcode file-system synchronized groups: every file under
`App/` and `Tests/` is part of its target automatically. Do not add file
references to `project.pbxproj`.

**Models.** `Core/` holds `ObservableObject` models (`ControllerAppModel`,
`LocalDevicesModel`, `RemoteSessionModel`, …) ported from the SwiftUI app with
their revision/cancellation logic intact. They are the only place that talks
to the packages. Their behavior is covered by the lifecycle tests; change
them only with a matching test.

**Screens** are `RCViewController` subclasses created by `AppRouter` from a
typed `AppRoute`. Each receives the scene's `AppEnvironment` (models, router,
appearance, lifecycle). Screens observe models through `RenderScheduler`,
which coalesces `objectWillChange` into one `render()` per run-loop turn; a
screen's `render()` diffs the new state into existing views and never
recreates the hierarchy. Pure "view state" builders (model → display values)
are kept free of UIKit so they can be unit-tested.

**Navigation.** One `RCNavigationController` rooted at Devices, bar hidden,
edge-swipe back preserved (`allowsInteractivePop` lets a screen veto it).
Status bar style, home indicator and deferred screen edges follow the top
screen. Pairing success pops to Devices (`AppRouter.startObservingPairing`).

**Presence and global errors.** `AppEnvironment` owns the presence heartbeat
(runs while the scene is active and a relay is selected, restarts on identity
change) and presents `presentedError` / local-device errors as dialogs.

## Design language

"Warm instrument": calm grounds, precise hairlines, one signal color, motion
that explains cause and effect. Built like shadcn/ui on iOS: small set of
composable primitives, semantic tokens, no decoration without a job.

- **Palette.** Exactly the web client's two token sets (`web/src/index.css`):
  *Warm* (parchment, ink, terracotta signal, sage online) and *Console*
  (charcoal, amber signal, green online). Front-door screens follow the
  Appearance setting (System / Warm / Console); the remote stage and camera
  scanner are always Console on black. Use `RCColor` tokens only.
- **Type.** San Francisco with tightened tracking on large sizes; SF Mono for
  addresses and metrics; tabular digits for live numbers. `RCTextStyle`
  covers everything; all styles support Dynamic Type with sane caps.
- **Shape.** Continuous corners: 12 controls, 16 cards, 20 menus/toasts,
  26 sheets/dialogs. 1 px hairline borders (`line`), strong borders
  (`lineStrong`) only on inputs and secondary buttons.
- **Depth.** Two quiet elevations: cards (contact + soft ambient shadow) and
  overlays (menus, dialogs, sheets). Shadows always from explicit paths. No
  glassmorphism and no blur over animated content.
- **Icons.** Lucide, 2 px optical stroke at 24 pt (thinner at small sizes),
  tinted by tokens. Every icon-only control has an accessibility label.
- **Motion.** Springs from `RCMotion` (`standard`, `snappy`, `smooth`,
  `bouncy`), interruptible property animators, Core Animation for anything
  continuous. Press feedback within 1 frame. Under Reduce Motion movement
  becomes a short crossfade. Haptics follow `RCHaptics` semantics.
- **Layout.** 20 pt gutters, 620 pt readable column on wide screens, 44 pt
  minimum hit targets, content respects safe areas and the keyboard.

## Performance rules

1. No work on the main thread that scales with time: continuous effects run
   on the render server (Core Animation) and pause off-screen.
2. Never rebuild view hierarchies on state change; diff into existing views.
   Frame-based layout (`layoutSubviews` + `sizeThatFits`) in lists and in
   chrome that updates frequently; Auto Layout only in static forms.
3. Shadows need `shadowPath`; no `masksToBounds` + `cornerRadius` on views
   with shadows; avoid offscreen passes (masks, group opacity on big trees,
   `shouldRasterize` on changing content).
4. Resolve dynamic colors into layers in `updateAppearance()`; wrap
   non-animated layer writes in `withoutImplicitAnimations`.
5. Cache fonts (`RCTypography`), icon paths/images (`RCIcon`), and text
   measurements that are reused during layout.
6. The video path (`RctlRemoteVideoView`) is owned by RctlRealtime; the
   remote screen must not add layers, blurs or transforms above the video
   that force recomposition every frame beyond simple opaque chrome.
7. Launch does no network, discovery or WebRTC work before first frame.

## Accessibility

VoiceOver labels, traits and values on every control; state is never color
alone (badges have text); Dynamic Type through `RCLabel`/`RCTypography`;
Reduce Motion honored by all motion helpers; 44 pt targets; `View` mode
blocks all remote input and is the default after every (re)connection.
