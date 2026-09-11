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

`Devices` is the product's front door and is allowed to be expressive where the
control surface is not: a warm parchment canvas with two soft color washes and
a slowly drifting constellation of particles, sharing the web client's `.warm`
theme (terracotta signal on cream, sage for healthy state). Content sits on
translucent parchment surfaces so the field stays visible without competing
with rows.

Each row contains the device name, its address or build detail, one semantic
status chip (dot plus text, never color alone), and a chevron. Local rows show
best-effort reachability from the bounded capabilities probe (`Saved`,
`Checking`, `Online`, `Offline`); the probe never gates opening a device, which
always runs its own preflight. Relay rows show `Online`, `Offline`,
`Needs update`, or `Incompatible`; an unavailable relay row explains itself in
an alert instead of opening an empty viewport. Edit and Remove live in the row
context menu.

`Nearby` is its own group with a stable shape across states so rows never
jump: a header with a searching indicator, `Search again`, and `Stop`; rows
for advertised services with `Resolving`, `Discovered`, `Saved` (exact
endpoint match with a saved entry), `Checking`, `Incompatible`, or
`Unsupported`; and one trailing state row, either the searching placeholder,
`No devices found`, `Local Network access is off` with Settings, or
`Discovery is unavailable` with retry. Every state keeps `Add by address` one
tap away. Discovery is opt-in: before the first opt-in the group shows a single
`Find devices on this network` row, so the system permission prompt appears in
context. A caption under the group states that found devices are not verified.
Saved rows whose address is currently advertised show `Discovered`, never
`Online`; only a capabilities probe earns `Online`, and none of this claims
ownership. Saved devices are never removed because they left `Nearby`.

Choosing a nearby device re-resolves it and runs the preflight, then either
opens a saved entry with the same address directly or presents a short
decision sheet: name, address, `Answered just now`, a trust note, and the
actions `Open in View mode`, `Save device`, and `Use this address for a saved
device…`. Saving or replacing pushes the local-device editor in `Save device`
or `Update address` mode; the latter shows the current and found addresses side
by side and states that only `Replace address and connect` changes the entry.

Every destination is a push in one `NavigationStack` (pairing intro, scanner,
local-device editor, control), so the system back gesture and button always
work; the nearby decision sheet is the one transient surface and never carries
a destination itself. The stack root owns the presentation style:
parchment screens are light; the scanner and the media stage are dark. A pushed
view cannot override an ancestor's `preferredColorScheme`, so the scheme is
decided once from the current route rather than per screen.

The first-run state is deliberately quiet and has the same shape as the
populated screen: the title with `No devices yet.`, the `Nearby` group with its
single opt-in row, one group with `Pair with relay` and `Add by address`, and a
one-line caption. There is no hero card, emblem, marketing heading, or explainer
tiles; the ambient canvas is the only expressive element. The header carries the
brand mark, the `rctl` wordmark, refresh when a relay profile exists, and an add
menu.
The product name shown to the user is `rctl`; `RCTL Controller` remains only
the Xcode target and scheme name.

### Pairing

Pairing is a short native flow: an intro with three numbered steps, then a
full-screen scanner. The scanner dims the camera except for a clear window with
rounded corner brackets. The window rests centered and breathes slowly, springs
onto a detected code, turns green with a check for a short lock-on, then claims
the code in place behind a progress card. Codes that are not pairing payloads
are called out in amber without a network round trip; a failed claim shows the
error and ignores the same payload for a few seconds so an expired code cannot
loop. Bottom controls are a white back circle, `Paste code`, and a torch toggle.
Denied or missing camera states offer Settings and paste. Raw JSON, tokens, and
URLs are never primary UI.

### Control

The live screen is full-bleed inside safe areas and uses a black media stage so
letterboxing is intentional. The header carries a persistent access-path badge,
`LAN` with a Wi-Fi glyph or `Relay` with a globe, beside the connection state
in every session state. The badge is neutral in color on purpose: LAN means a
trusted network, not an authenticated pairing. Session Controls repeats the
path with the endpoint and a factual trust line, `Trusted network · not
paired` or `Authenticated controller`. Portrait and landscape content preserve aspect
ratio and input mapping; controls cannot resize the media when labels or status
change.

The top overlay contains Back, device name, connection path, and More. The
bottom overlay contains only high-frequency controls: keyboard, Home,
orientation, sound, Talk, and camera. Controls fade after inactivity and return
on a single tap that is not forwarded to the device. A visible locked-control
state prevents the reveal gesture from becoming an accidental remote touch.

On iOS, keyboard opens an inline composer above the system keyboard rather than
covering the viewport with a destination sheet. A horizontally scrollable key
row exposes Escape, Tab, Return, Backspace, Forward Delete, and arrows. Text is
sent only on an explicit command; unsupported input remains in the composer with
an actionable error instead of partially mutating the controlled device.

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
separators, materials, and navigation components. Do not ship a third-party UI
kit or custom font. The application has two deliberate appearances: the warm
parchment theme for Devices, pairing, and editors, and a black media stage for
control and the camera scanner. Parchment screens stay light regardless of the
system appearance because the palette is part of the product identity; the
stage stays dark.

The palette mirrors the web client's `.warm` theme: ink text on cream and
parchment surfaces, terracotta as the signal color for the primary commit
action, focused control, and attention, sage for healthy/online, and a muted
red for destructive/error. Every status also has text or an icon. Platform
accessibility contrast, Increase Contrast, Differentiate Without Color, and
Reduce Motion override decoration.

Decoration is confined to the ambient canvas behind the parchment screens: two
soft radial color washes and a constellation particle field. The field is a
pure function of time with no accumulated state, is seeded per canvas size so
rotation does not re-roll it, pauses when its screen is not visible or the
scene is inactive, and freezes under Reduce Motion. Surfaces are translucent
parchment with a hairline border and a soft shadow, at most one level deep; do
not nest surfaces, and do not bring the canvas or decorative gradients into
the operational control UI.

Spacing follows each platform's native rhythm. Buttons are capsules: ink for
the default primary action, terracotta for the commit action of a flow, and an
outlined parchment secondary. Icon buttons have stable 44-point targets.

Motion communicates lifecycle: connection transition, controls appearing,
pushes, the scanner reticle following a code, and successful state change. It
is short, interruptible, and omitted under Reduce Motion. The particle field
and the first-run emblem halo are the only ambient animations.

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
