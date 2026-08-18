# rctl — Architecture & Engineering Notes

Remote-control system for a jailbroken iPad: view the screen, hear the device's
real playback audio, inject touch/keyboard/buttons from a browser, plus camera,
file transfer, a root web terminal, automation, and device control. "scrcpy /
AnyDesk for jailbroken iOS." LAN today; internet is the north star.

Target device this was built on: **iPad Air 3 (A12, arm64e), iOS 14.4, unc0ver +
Substitute** (NOT Cydia Substrate), with Choicy + Heimdallr installed.

Why jailbreak is required: App Store remote apps (TeamViewer/AnyDesk/RustDesk) can
only *view* an iOS screen — they can never inject input. Only root + a jailbreak's
AMFI bypass enable real touch/keyboard injection and camera-from-any-app.

---

## 1. Component map

```
  ┌─────────── iPad (jailbroken) ────────────────────────────┐
  │                                                          │
  │  SpringBoard ──[rctlsbcap.dylib]──┐   every app ──[rctlapp.dylib]
  │   screen capture + H.264 encode   │    camera capture in the
  │   touch/key injection             │    FRONTMOST app
  │   SB private-API actions          │         │ raw-socket POST
  │   local output control            │         ▼
  │         │ Unix socket IPC         │   ┌──────────────┐
  │         ▼                         │   │ /v1/cam_upload│
  │   rctld  (root daemon) ◄──────────┘   └──────────────┘
  │   HTTP :8080  (live /stream + REST /v1/*)              │
  │         ▲                                                │
  │         │ TCP 127.0.0.1:8079 PCM                         │
  │  mediaserverd ──[rctlaudio.dylib] system playback audio │
  └─────────┼────────────────────────────────────────────┘
            │ Wi-Fi / USB (iproxy) or relay/WebRTC
            ▼
       Browser (`web/` control app): video, audio, input, files, console
```

Five runtime parts ship in one `.deb` (`com.greatlove.rctl`):

| Component | Where it runs | What it does |
|---|---|---|
| **rctlsbcap** (`springboard/`) | injected into SpringBoard | screen capture → VideoToolbox H.264 → IPC; touch/key injection; SB private APIs (Control Center, Cover Sheet, launch, alert, toast, clipboard, brightness, FX speak/sound/flash/banner); orientation; idle/active gating |
| **rctld** (`daemon/`) | root daemon (launchd KeepAlive) | HTTP server (chunked `/stream` + REST `/v1/*`), WebSocket terminal `/ws/term`, relays between browsers and SpringBoard over a local Unix socket; concurrent (thread-per-connection) |
| **rctlapp** (`app/`) | injected into **every** app | captures camera stills and live front/rear video in the foreground app; app-side VideoToolbox sends bounded H.264 to rctld |
| **rctlaudio** (`audio/`) | inactive payload for mediaserverd | activated only during `/v1/audio_capture`; copies system playback PCM from supported AudioQueue/AudioUnit paths and forwards it to rctld |
| **web** (`web/`) | the controlling browser | React/Vite control app. Primary path is WebRTC (H.264 RTP track + DataChannels); `/stream` WebCodecs remains a local/fallback path. `web/legacy/` keeps the old vanilla client for reference only. |

`core/` holds the shared C/C++/ObjC modules (capture, encode, stream, net, input,
ipc) so rctlsbcap, rctld, and the media payloads don't duplicate code. `layout/`
is the static package payload (LaunchDaemon plist and maintainer scripts);
`Makefile` stages `web/dist/index.html` into `/var/mobile/rctl/index.html`.
`relay/web-admin` is a separate admin SPA embedded into
`relay/internal/relay/webdist`; it is not the device control UI. `docs/` holds
these notes + the mediaserverd class dump.
`scripts/deploy.sh` is the one-command safe deploy.

---

## 2. Data flow

**Screen → browser.** rctlsbcap captures the framebuffer via
`CARenderServerRenderDisplay` (off a render timer), encodes H.264 with
VideoToolbox, and ships Annex-B access units over the IPC socket to rctld. rctld
feeds the same access units to open WebRTC RTP video tracks and, for fallback,
to `/stream` subscribers as HTTP chunks with app-framing
`[1B type:0=delta,1=key,2=orient,3=reset][4B BE len][data]`. Capture/encode run
**only while a viewer is connected** (idle-by-default, §4).

**Input → device.** The browser sends `GET /input?phase=&id=&x=&y=` (touch) and
`/key?p=&u=&d=` (keyboard/buttons). rctld forwards them over IPC to rctlsbcap, which
injects a **digitizer IOHIDEvent tagged with the real hardware senderID** so the
foreground app receives it (works in all apps/games, not just SpringBoard).

**Audio → browser.** `rctld` activates the inactive `audio/` payload only on
`/v1/audio_capture?on=1`. After a coordinated mediaserverd restart,
`rctlaudio.dylib` copies supported Linear PCM from playback paths into a bounded
queue and sends timestamped packets to `rctld` over `127.0.0.1:8079`. `rctld`
broadcasts them on `/stream` as frame type `4`; the browser schedules playback
with Web Audio.

**Device audio output.** `/v1/audio_output?device=1|0|status=1` controls whether
the iPad itself stays audible while the browser receives audio. Muting saves the
previous volume and restore re-applies it.

**Terminal.** `/ws/term` upgrades to a WebSocket and bridges raw binary frames to
a root PTY shell created with `forkpty()`. xterm.js in the browser handles ANSI
colors, cursor movement, Ctrl-C, and resize. See `docs/TERMINAL.md`.

**Automation.** REST `/v1/*` (tap/swipe/type/button/launch/alert/toast/clipboard/
brightness/openurl/apps/files/say/sound/flash/banner/camera/script/audio_capture/
audio_output) — curl- and script-friendly, separate from the realtime plane,
shares the IPC action path where SpringBoard context is required.

**Camera → browser.** Stills use `/v1/camera?pos=` and a one-shot foreground-app
JPEG upload. Live camera uses daemon-owned desired state, `AVCaptureVideoDataOutput`
and VideoToolbox inside the foreground app, framed loopback ingest on :8081, and a
dedicated H.264 WebRTC PeerConnection. See `docs/CAM.md`.

**IPC.** Unix socket `/var/run/rctl-ipc.sock`, framing `[1B type][4B BE len][payload]`.
Daemon listens (chmod 0777 so mobile-uid SpringBoard can connect); SB connects with
retry and auto-reconnects when the daemon restarts. Request/response (clipboard,
device info, app list, audio output status) uses a reqid + dispatch_semaphore on
the daemon side. Audio ingest is intentionally separate from this command channel.

---

## 3. The hard problems, and how they were solved

These are the non-obvious wins. Each cost real reverse-engineering.

**System-wide touch injection.** The naive path (enqueue into SpringBoard's
UIApplication with a fake senderID) only controls SpringBoard. The working method:
build a digitizer `IOHIDEvent` with **normalized [0,1] fixed-space coords** and the
**real hardware digitizer senderID** (captured once from a physical touch via
`IOHIDEventSystemClientRegisterEventCallback`, persisted to disk keyed by
`KERN_BOOTTIME`), then `IOHIDEventSystemClientDispatchEvent` — no `_enqueueHIDEvent:`,
no contextID. The genuine sender id makes the system route the event to the
foreground app. Coords are in the screen's FIXED (orientation-independent) space.

**Idle-by-default power saving.** Capture + encode + the keep-awake idle-timer ran
24/7 from boot → the display never slept and the battery drained (80%→12% in ~6h
idle). Fix: run the pipeline **only while a viewer is connected**. rctld fires a
session callback on the `/stream` subscriber count crossing 0↔1; SB starts/stops
capture, keep-awake, and the orientation timer. Opening the viewer is itself the
wake signal (Wake-on-LAN / APNs pattern: cheap always-on listener, expensive media
on demand). Whether the screen actually sleeps then depends on the device's iOS
Auto-Lock setting (we no longer override it).

**Camera from ANY open app (the big one — see §5).**

**Roaming live camera.** `rctld` owns desired state and a generation; the currently
active foreground app owns `AVCaptureSession`. App switches transfer ownership,
Home reports `waiting_for_app`, and a browser lease prevents orphaned capture.
Camera RTP uses a separate PeerConnection because the iOS SRTP backend is kept to
one media SSRC per connection. See `docs/CAM.md`.

**System playback audio.** App audio is mixed inside mediaserverd, not SpringBoard
or the root daemon. The working boundary is a mediaserverd payload that copies PCM
from supported AudioQueue/AudioUnit playback paths and sends it to `rctld`. The
payload is opt-in, removable, guarded by a TTL watchdog, and coordinated with
video capture because restarting mediaserverd can stall the current H.264 session.

**Orientation.** Screen: the foreground app's `FBSOrientationObserver
activeInterfaceOrientation` (correct even for force-orientation apps), debounced.
Camera: set the capture connection's `videoOrientation` to the app's
`statusBarOrientation` (UIInterfaceOrientation 1..4 maps 1:1 to
AVCaptureVideoOrientation). FX overlays: size to `fixedCoordinateSpace.bounds` and
rotate the content to the current orientation (a SpringBoard window doesn't rotate
with the UI).

---

## 4. Idle/active gating detail

- IPC message `RCTL_MSG_ACTIVE [1B]` (daemon→SB).
- rctld `on_session(active)`: serialize on a GCD queue, debounce idle by 4s (no
  thrash on refresh/Wi-Fi blip), and re-sync state to SB on (re)connect.
- SB `rctl_set_active(on)`: start/stop the capture session, the keep-awake timer,
  and the orientation timer. `%ctor` no longer starts them — idle until a viewer
  connects.

---

## 5. Camera — the full story (most reverse-engineering went here)

**The gate.** iOS only lets the **frontmost app** use the camera. mediaserverd
enforces it: a daemon or SpringBoard is rejected at hardware client validation
(`BWFigVideoCaptureDevice initWith…applicationID:clientAuditToken:error:` returns
`-16401`; no `FigCaptureClientSessionMonitor` is even created, so the
foreground-state hook in mediaserverd can't help). Proven by injecting a diagnostic
dylib into mediaserverd (`docs/mediaserverd-capture-classes.txt` is the class dump).
SpringBoard never even reaches mediaserverd (its sandbox forbids it as a camera
client).

**The solution: capture IN the frontmost app.** `rctlapp` is injected into every app
(`Filter.Bundles = com.apple.UIKit`). On a Darwin-notification pulse from rctld, the
foreground-active app (a *valid* camera client) silently grabs a still with
`AVCaptureStillImageOutput` (driven via the ObjC runtime to dodge the AVFoundation
umbrella build issue), then ships it back. SpringBoard is explicitly excluded (it
reports Active but can't capture and would race the real app for the device).

**Three App-Store-app problems, all solved:**
1. **usage-description SIGABRT** — accessing the camera without an
   `NSCameraUsageDescription` aborts the process. Fix: `%hook NSBundle
   objectForInfoDictionaryKey:` returns a camera string for the main bundle.
2. **TCC** — the app agent gates private TCC preflight/request hooks only while an
   rctl-owned capture session is active. Package scripts no longer insert or
   delete camera rows in TCC.db; deleting broad rows could destroy user grants.
3. **Sandbox + ATS** — a sandboxed App Store app can't write `/tmp` (outside its
   container) and ATS blocks `NSURLSession http://`. Fix: rctlapp POSTs the JPEG over
   a **raw loopback socket** (`connect 127.0.0.1:8080`, hand-written HTTP) — exempt
   from ATS, allowed by the sandbox; the root daemon writes the file.
   This also forced the HTTP server to become **thread-per-connection**, because
   `/v1/camera` (which polls for the upload) would otherwise deadlock the in-app
   `/v1/cam_upload`.

**Limitation.** Works only while an *app* is foreground. On the home screen the
frontmost "app" is SpringBoard, which can't capture — the user just opens any app.

**Live path.** `/v1/cam_live` keeps desired state in `rctld`. The active app uses
`AVCaptureVideoDataOutput`, encodes bounded 640x480 frames with VideoToolbox, and
sends Annex-B H.264 to loopback port 8081. `rctld` forwards it through a dedicated
camera WebRTC PeerConnection and may write the same access units to MPEG-TS. A
30-second browser lease and five-second app heartbeat stop orphaned capture. See
`docs/CAM.md` for protocol and validation details.

**Why not the daemon-side approaches:** a standalone helper (`rctlcam`, since
removed) with `com.apple.private.tcc.allow` + an embedded usage-description got
`authorizationStatus=3` but the session was still rejected at the hardware
validation — confirming the capturer must be a real foreground app.

---

## 6. Internet access (P3, the north star) — roadmap

Goal: control the iPad from anywhere, low latency, behind any NAT, self-contained.

| Approach | Latency | Effort | Notes |
|---|---|---|---|
| **Relay via VPS** | medium | low | daemon holds an *outbound* tunnel to a cheap VPS; browser connects to the VPS; it forwards. Reuses our HTTP. Works behind any NAT. Doubles as the always-reachable channel for a sleeping device (APNs pattern). |
| **WebRTC** (libdatachannel / libwebrtc) | lowest (P2P) | high | cross-compile under arm64e iOS 14 + a TURN server (coturn) + signaling. libdatachannel is lighter than full libwebrtc. |

**Recommendation:** ship the **relay first** (a tiny Go/Node relay on a $5 VPS + a
reverse tunnel from rctld), get internet working fast, then evolve the media path to
WebRTC if latency demands it, keeping the relay for signaling. "Ship, then optimize."

**Prerequisite: auth.** Today `:8080` has no authentication (LAN-only is the
implicit boundary). Before exposing anything to the internet, add a token/password
gate (and ideally TLS, or rely on the relay's TLS). This is non-negotiable for the
internet phase.

---

## 7. Build, deploy, and on-device gotchas

- **Theos aggregate** (`SUBPROJECTS = springboard daemon cap`). One `.deb`.
- **On-device re-sign with `ldid -S`** in `postinst` — macOS ad-hoc signatures are
  rejected by on-device AMFI on arm64e (the binary loads non-executable → SIGBUS).
- **Never upgrade-in-place.** Upgrading a dylib over a running SpringBoard leaves a
  stale codesign state → SpringBoard SIGBUS-crashes at load and can loop into
  Substitute safe mode. `deploy.sh` does `dpkg -r` (clean respring) then `dpkg -i`,
  under a watchdog that disables the dylib + resprings if a new crash appears.
- **`mediaserverd` audio payload** (`audio/`) needs `killall mediaserverd` to
  load/unload. `rctld` coordinates this by idling video capture, restarting
  mediaserverd, signaling a stream reset, and resuming video if a viewer remains.
  Do not manually kill mediaserverd while streaming.
- **Same-basename `.o` collision:** two subprojects both named `Tweak.xm` collide in
  `.theos/obj`. Name each tweak's source after the tweak (`rctlsbcap.xm`,
  `rctlapp.xm`). This is also the answer to "Tweak.xm vs rctlcam.xm": unique names
  per tweak in a monorepo.
- **AVFoundation umbrella won't build in a `.xm`** — it drags in camera/simd headers
  whose libc++ `<cmath>` isn't on the include path. Drive AVFoundation classes via
  the ObjC runtime (NSClassFromString + objc_msgSend), no header import; link the
  framework only.
- **C functions in a `.mm`/`.xm`** need `extern "C"` prototypes (else the C++-mangled
  symbol isn't found at link, e.g. `AudioServicesPlaySystemSound`).
- **ARC + dispatch sources:** a helper taking `dispatch_source_t *` needs the
  `__strong` qualifier; forward-declare functions used before their definition.
- **No `awk`/`seq`/`defaults`/`plutil -p`** on this device; `plutil -key`, `sqlite3`,
  `dpkg`, `ldid`, `cut` are present.
- **Wi-Fi `greatlove` / 192.168.178.45 is reliable**; the USB iproxy tunnel (2222)
  is flaky. Deploy with `RCTL_SSH=greatlove scripts/deploy.sh`.
- After a deploy/respring the first camera capture can `http=000` for a few seconds
  while the device settles — retry.

---

## 8. Security posture (honest)

- **Camera access hooks run inside UIKit apps** = a sensitive trust boundary.
  They are gated to rctl capture lifetime; capture requires foreground state,
  and iOS 14 shows the camera-in-use indicator. Outside that lifetime the hooks
  return the original TCC result. Package scripts own no persistent TCC rows and
  therefore delete none on uninstall. TCC is still per-process, so this boundary
  must be revalidated for every supported jailbreak/iOS combination.
- **`:8080` is unauthenticated.** Fine on a trusted LAN; **must** gain auth before
  internet exposure (see §6).
- **The daemon is root** and exposes file read/write (`/v1/ls,pull,push,rm`), app
  launch, input injection, and a root PTY terminal. Anyone who reaches `:8080`
  controls the device.
- The screen stream and camera are obviously sensitive; the whole system is a
  surveillance/remote-admin tool by design and should only run on a device the
  operator owns.

---

## 9. iOS 17 / 18 porting considerations (future)

Plan: a used iPhone on a Dopamine-style (rootless) jailbreak. Expected work:
- **Rootless paths:** binaries/dylibs/plists move under `/var/jb/...`. Update the
  layout, the LaunchDaemon path, the MobileSubstrate dir, and any absolute paths.
- **Injection layer:** ElleKit (Dopamine) instead of Substitute; the `%hook`/filter
  model is the same, but verify selectors.
- **Still capture API:** `AVCaptureStillImageOutput` is deprecated; on newer iOS use
  `AVCapturePhotoOutput` with a (runtime-built) delegate, or `AVCaptureVideoDataOutput`
  grabbing one sample buffer. The **frontmost-app capture technique is
  version-independent** — only the capture call changes.
- **TCC.db schema** and the camera codename may differ; re-verify the INSERT columns
  and `kTCCServiceCamera`.
- **Private APIs** (SpringBoard selectors, FBSOrientationObserver, the senderID flow,
  CARenderServerRenderDisplay) shift between versions — expect a re-probe pass.
- **arm64e / AMFI / entitlements:** the re-sign and entitlement story changes with
  the jailbreak; on rootless, code signing and the trust cache work differently.
- The architecture (3 tweaks + root daemon + web) ports cleanly; the device-specific
  glue (paths, selectors, capture API) is what needs redoing.

---

## 10. Known limitations / TODO

- Internet access (relay → WebRTC) — not started (§6).
- Auth on `:8080` — required before internet (§6, §8).
- WebSocket realtime channel — deferred; chunked HTTP + REST works today.
- Camera works only with an app foreground (§5).
- Settings/PreferenceBundle — deferred ("we don't know what they'll be yet").
- A README at the repo root would help newcomers; this file is the deep reference.
