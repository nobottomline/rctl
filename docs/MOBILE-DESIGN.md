# Native Mobile Product Design

Status: design direction for the planned iOS and Android controllers. This
document defines product behavior and visual constraints; it is not evidence
that the application hosts or realtime media path have shipped.

## Direction

rctl is a quiet native control surface for a device the user already owns. It
must feel closer to a focused system utility than to a web dashboard, consumer
social product, or branded remote-desktop skin.

The remote viewport is the product. Navigation and controls exist to make that
viewport dependable, understandable, and safe. They must not compete with the
controlled screen, hide connection state, or turn every daemon endpoint into
an equally prominent button.

The reference review used currently accessible iOS screens in Mobbin on
2026-08-24. Apple Home informed compact device status and native menus; Meetup
informed search and filter density; CLEAR, ShopBack, and Yami were useful
counterexamples for brand-heavy or commerce-heavy composition; Venmo, Flighty,
and Swiggy informed permission and confirmation dialogs. Specialized libraries
such as Tesla and Retro were visible but their detailed flows required Mobbin
Pro, so no inaccessible screen is treated as evidence. No third-party image,
layout, or asset is copied into rctl.

## Information Architecture

The first screen is `Devices`. An available device opens directly into
`Control`; an unavailable device opens its status and recovery actions instead
of an empty viewport.

```text
Devices
  Device status / diagnostics
  Control
    Live viewport
    Input and orientation
    Sound and Talk
    Camera
    More
      Files
      Photos
      Terminal
      System actions
      Update
Settings
  Relay profiles
  Controllers and security
  Appearance and accessibility
  Diagnostics and legal
```

`Files`, `Photos`, and `Terminal` are destinations within the selected device,
not global tabs. The bottom navigation must not contain features that are
meaningless before a device is selected. On iPad and large Android windows the
same hierarchy may become a two-column sidebar/detail layout without changing
feature ownership.

## Core Screens

### Devices

Use a compact native list, not a grid of decorative cards. Each row contains
the device name, model, one connection state, last-seen text when relevant, and
one restrained disclosure affordance. Online rows open Control with one tap.

Connection state is semantic and never color-only:

- `Connected`: active session and current route;
- `Available`: device can be opened;
- `Connecting`: cancellable progress with elapsed time;
- `Degraded`: usable session with a concise warning and diagnostics action;
- `Offline`: last seen and recovery actions;
- `Incompatible`: both protocol versions and the required next action;
- `Revoked`: credential recovery, never an endless reconnect spinner.

Relay profiles and pairing live in toolbar actions or Settings. Enrollment is a
short native flow: scan QR, verify relay identity and requested scopes, name the
controller, then store the resulting key in platform secure storage. Raw JSON,
tokens, and URLs are never primary UI.

### Control

The live screen is full-bleed inside safe areas and uses a black media stage so
letterboxing is intentional. Portrait and landscape content preserve aspect
ratio and input mapping; controls cannot resize the media when labels or status
change.

The top overlay contains Back, device name, connection path, and More. The
bottom overlay contains only high-frequency controls: keyboard, Home,
orientation, sound, Talk, and camera. Controls fade after inactivity and return
on a single tap that is not forwarded to the device. A visible locked-control
state prevents the reveal gesture from becoming an accidental remote touch.

Use SF Symbols on iOS and Material Symbols on Android for familiar actions.
Icon buttons have stable 44-point/48-dp targets, accessibility labels, selected
state, and a tooltip on pointer-capable devices. Text buttons are reserved for
commands whose meaning cannot be represented safely by a familiar symbol.

Connection recovery is inline and actionable. A transient handoff keeps the
last decoded frame with `Reconnecting` and Cancel; authentication failure,
protocol mismatch, and offline state use distinct messages and actions. Never
show an indefinite generic spinner over a stale frame.

### Sound And Camera

Sound uses independent native toggles for app audio, iPad output, room
microphone, and the Talk route. Push-to-talk is a large momentary control with a
clear pressed state, route name, microphone permission state, and immediate
release on backgrounding or session loss. It is not a sticky toggle disguised
as a button.

Camera opens the separate camera session without replacing the screen session.
Front/back, recording, and close are compact overlay controls. Recording always
shows elapsed time and destination; interruption produces a recoverable partial
result or an explicit failure, never a silent disappearance.

### Files And Photos

Files use a native hierarchical list with stable rows, file-type icons, size,
modified date, selection mode, progress, cancellation, share, and download
destination. Long paths truncate in rows but are shown in full before a
destructive action.

Photos use an edge-to-edge adaptive thumbnail grid grouped by date. `All`,
`Photos`, and `Videos` are a segmented filter; the navigation title reflects the
selection and count (`Media · 24`, `Photos · 18`, `Videos · 6`). A Live Photo is
one asset with a Live badge and press-to-play behavior, not duplicate photo and
zero-duration video cells. Context menus expose Preview, Share, Save, Copy, and
Delete according to capabilities. Multi-select supports batch share/save/delete
with progress and partial-failure results.

### Terminal And Dangerous Actions

Terminal uses a real terminal renderer in an immersive destination with a
keyboard accessory row and explicit disconnect state. Root access and optional
biometric policy are visible before opening it.

Destructive actions use native confirmation sheets. The final prompt names the
operation, device, and full normalized target path or package id. It obtains the
one-time confirmation token only after the user commits and never repeats an
action automatically after reconnect. Destructive commands use the platform
destructive color exclusively.

## Visual System

Use platform system typography, Dynamic Type/font scaling, semantic system
backgrounds, separators, materials, and navigation components. Do not ship a
third-party UI kit or custom font for the first product cycle. The application
supports light and dark appearance; the live media stage remains black.

The brand accent is a restrained warm signal color derived from the existing
web client. It may mark the active route, primary commit action, recording, or
focused control, but must not tint entire screens. Green means healthy/online,
amber means attention/transition, and red means destructive/error. Every status
also has text or an icon. Platform accessibility contrast, Increase Contrast,
Differentiate Without Color, and Reduce Motion override decoration.

Spacing follows each platform's native rhythm. Repeated items may use bounded
surfaces with at most an 8-point visual corner radius unless a standard system
component owns a different radius. Do not nest cards, float page sections in
cards, add decorative gradients/orbs, or use large marketing headings inside
the operational UI.

Motion communicates lifecycle: connection transition, controls appearing,
sheet presentation, and successful state change. It is short, interruptible,
and omitted under Reduce Motion. There is no ambient animation.

## Shared Tokens, Native Components

Share semantic names and intent as reviewed data, not rendered components:

```text
color.signal / color.healthy / color.warning / color.destructive
spacing.compact / spacing.standard / spacing.section
motion.immediate / motion.standard
icon.home / icon.keyboard / icon.rotate / icon.audio / icon.mic / icon.camera
```

iOS implements them in Swift and `Assets.xcassets`; Android implements them in
Kotlin and resources. Typography, navigation, sheets, context menus, haptics,
safe areas, and accessibility remain platform-native. Pixel identity between
iOS and Android is not a goal; behavioral and semantic parity is.

## Required States And Validation

Every screen is designed and tested in loading, empty, populated, stale,
offline, denied, incompatible, revoked, partial-failure, and retry states where
applicable. Previews and screenshot tests use synthetic fixtures with no
production hostnames, credentials, identifiers, or captured media.

Before accepting a screen:

- verify the smallest supported phone, a current large phone, landscape, and a
  tablet/window layout;
- verify the largest accessibility text size without clipped commands;
- verify VoiceOver/TalkBack order, labels, values, actions, and focus recovery;
- verify touch targets, keyboard/pointer use, contrast, Reduce Motion, and
  Differentiate Without Color;
- verify offline and reconnect behavior against the real session coordinator;
- verify destructive prompts and cancellation against the real API contract;
- profile the viewport so overlays do not trigger video renderer churn.

Static visual approval is necessary but insufficient. Screen, camera, audio,
Talk, orientation, handoff, PiP, and background behavior require physical-device
qualification defined in `MOBILE-PLAN.md`.
