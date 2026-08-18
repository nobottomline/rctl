# rctl — remote control for jailbroken iOS

`rctl` ("remote control") is a low-latency remote desktop stack for a
**jailbroken iPad**: view the live screen, hear real device playback audio,
inject real touches and keyboard input, transfer files, open a root terminal, and
automate device actions from a browser or native client. Direct LAN and
authenticated self-hosted relay access are both implemented.

> Why jailbreak: Apple's iPhone Mirroring needs iOS 18 + the same Apple ID + a Mac + the
> same network. App Store apps (TeamViewer / AnyDesk / RustDesk) can only *view* an iOS
> screen, never control it. Only root on a jailbroken device enables real input injection.

## Status

Live screen streaming, real touch control, real iPad playback audio, files,
Photos/video browsing, camera stills, and a root PTY terminal work. Live
front/rear camera streaming, device-side recording, and browser-to-app virtual
microphone injection are implemented and awaiting final physical-device
qualification. A SpringBoard-injected agent
captures the display, hardware-encodes H.264 (VideoToolbox), and sends it to
`rctld`. The browser control app uses WebRTC for the current low-latency path
(H.264 RTP video track plus DataChannels for input/audio/files) and keeps the
local `/stream` WebCodecs path as compatibility fallback.

## Target device

| | |
|---|---|
| Model | iPad Air 3 (`iPad11,3`) |
| SoC | A12 Bionic (`arm64e`) |
| OS | iOS 14.4 (build 18D52) |
| Jailbreak | unc0ver (rootful, Substitute) — **semi-untethered** (must not reboot while unattended) |

## Repository layout

```
rctl/
├── core/           # shared C/ObjC++ modules, linked by the on-device targets
│   ├── capture/    #   screen capture (CARenderServerRenderDisplay → IOSurface) + keep-awake
│   ├── encode/     #   VideoToolbox H.264 encoder (+ GPU downscale)
│   ├── stream/     #   capture→encode session loop
│   ├── net/        #   HTTP server: WebCodecs stream + /input + /config (linked into rctld)
│   ├── input/      #   touch (+ keyboard) injection via IOHIDEvent (runs in SpringBoard)
│   ├── ipc/        #   SB↔daemon Unix-socket message channel (video↑, input↓)
│   └── vendor/     #   vendored private headers
├── springboard/    # the injected agent (rctlsbcap): capture + encode + inject (thin)
├── daemon/         # rctld — root daemon (launchd KeepAlive): hosts the transport + relay
├── audio/          # rctlaudio — inactive mediaserverd system-audio payload
├── app/            # rctlapp — foreground camera and virtual-microphone agent
├── web/            # canonical React/Vite control app; build output is web/dist/
│   └── legacy/     #   old vanilla single-file client + vendor assets, reference only
├── relay/          # Go relay server + relay/web-admin admin SPA
├── layout/         # package payload: LaunchDaemon plist, web client, postinst/prerm
├── control         # Debian package metadata
├── Makefile        # Theos aggregate: builds every component into one .deb
└── docs/           # design & operational docs
```

The transport and REST API run in `rctld`, out of SpringBoard, so a network bug
does not respring the UI. SpringBoard streams encoded frames to it over a local
socket and receives input/actions back. `audio/` is built into the package as an
inactive payload and is copied into the active MobileSubstrate path only while
browser audio capture is enabled.

## Transport / decode decision

- **Primary browser app:** `web/` (React/Vite). `make package` stages
  `web/dist/index.html` as `/var/mobile/rctl/index.html`.
- **Primary live transport:** WebRTC via **libdatachannel** in `rctld`: H.264 RTP
  video track, reliable DataChannels for control/audio/files, relay signaling,
  and optional STUN/TURN for NAT traversal.
- **Compatibility fallback:** local `/stream` over HTTP chunked H.264 decoded
  with WebCodecs. The relay stream tunnel is kept for smoke/debug fallback, not
  as the preferred internet video path.
- **Internet packaging:** public release `.deb` files stay LAN-only. Relay-enabled
  packages are generated per user with `make package-relay` and must not be
  published. See `docs/RELAY.md`.

## Build & deploy

Requires Theos (`$THEOS`) and the iOS 14.5 SDK on macOS. The whole project is a Theos
aggregate package — build and install everything as a real `.deb` with one command:

```sh
# Default target is the USB tunnel — start it first:
iproxy 2222:22 8080:8080 &

make package install      # build .deb, copy it, dpkg -i, re-sign, respring
# over Wi-Fi instead:
THEOS_DEVICE_IP=<device-host> THEOS_DEVICE_PORT=22 make package install

# then open http://localhost:8080/  (USB)  or  http://<ipad-ip>:8080/  (Wi-Fi) in Safari
```

`make package` alone just builds `./packages/*.deb`. The package installs the agent to
`/Library/MobileSubstrate/DynamicLibraries/` and the web client to `/var/mobile/rctl/`,
shows up in Cydia as `com.greatlove.rctl`, and uninstalls cleanly.

> NOTE: the macOS `ldid` signature is rejected by on-device AMFI on arm64e, so
> `postinst` re-signs installed binaries with the device's own `ldid`. The SSH
> targets can be defined in `~/.ssh/config` (`rctl-device` is the default USB
> tunnel alias; choose a private alias for Wi-Fi).

## Roadmap

1. **P1 — done.** Screen capture + hardware H.264 + browser stream over LAN.
2. **P2 — done.** Real touch control through `IOHIDEvent`, correct in all orientations.
3. **P2.5 — working.** Real system playback audio, camera still/live, files, clipboard,
   Photos/video browser, app launch, root terminal, virtual mic, and automation endpoints.
4. **P3 — active.** Authenticated relay access with WebRTC media/control,
   relay-hosted control page, and TURN hardening.
