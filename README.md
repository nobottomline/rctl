# rctl — remote control for jailbroken iOS

`rctl` ("remote control") is a low-latency remote desktop stack for a **jailbroken iPad**:
view the live screen, inject real touches and keyboard input, transfer files — from any
browser or a native iOS client, over LAN or the internet. Think *scrcpy*, but for
jailbroken iOS, and reachable from anywhere.

> Why jailbreak: Apple's iPhone Mirroring needs iOS 18 + the same Apple ID + a Mac + the
> same network. App Store apps (TeamViewer / AnyDesk / RustDesk) can only *view* an iOS
> screen, never control it. Only root on a jailbroken device enables real input injection.

## Status

Live screen streaming **and real touch control** work: a SpringBoard-injected agent captures the
display, hardware-encodes H.264 (High profile, VideoToolbox), streams it over HTTP to a browser
(decoded with **WebCodecs**), and injects real touches back (`IOHIDEvent`) — correct in all 4
orientations. Resolution/fps/bitrate switch live; the display is kept awake during a session.
Next: keyboard input, and control inside 3rd-party apps.

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
├── core/           # shared C/ObjC++ modules, linked by the on-device target
│   ├── capture/    #   screen capture (CARenderServerRenderDisplay → IOSurface) + keep-awake
│   ├── encode/     #   VideoToolbox H.264 encoder (+ GPU downscale)
│   ├── stream/     #   capture→encode session loop
│   ├── net/        #   HTTP server: WebCodecs stream + /input + /config (moving to WebRTC)
│   ├── input/      #   touch (+ keyboard) injection via IOHIDEvent (runs in SpringBoard)
│   └── vendor/     #   vendored private headers
├── springboard/    # the injected agent (rctlsbcap): capture + encode + serve + inject
├── web/            # browser client (WebCodecs decoder, pointer/keyboard input)
├── layout/         # extra package payload (web client) + maintainer scripts (postinst/prerm)
├── control         # Debian package metadata
├── Makefile        # Theos aggregate: builds every component into one .deb
└── docs/           # design & operational docs
```

Planned, not yet created: `daemon/` (rctld — root daemon hosting transport + the REST
automation API, supervised by launchd), `relay/` (Go signaling + TURN), `proto/` (shared
protocol). The HTTP server lives in the SpringBoard agent today; it moves into `rctld` next
so a network/transport bug can't respring SpringBoard.

## Transport / decode decision

- **Decode: WebCodecs** (frame-level, low latency) — the client decoder, kept long-term.
- **Transport now (LAN/dev): HTTP chunked** — simple, good enough on a local network.
- **Transport for internet (P3): WebRTC** — DataChannel carrying encoded frames + WebCodecs
  decode (lowest latency, full control), with ICE/STUN/**TURN** for NAT traversal. On-device
  WebRTC via **libdatachannel** (lightweight) rather than libwebrtc. Signaling = small Go server.

## Build & deploy

Requires Theos (`$THEOS`) and the iOS 14.5 SDK on macOS. The whole project is a Theos
aggregate package — build and install everything as a real `.deb` with one command:

```sh
# Default target is the USB tunnel — start it first:
iproxy 2222:22 8080:8080 &

make package install      # build .deb, copy it, dpkg -i, re-sign, respring
# over Wi-Fi instead:
THEOS_DEVICE_IP=greatlove THEOS_DEVICE_PORT=22 make package install

# then open http://localhost:8080/  (USB)  or  http://<ipad-ip>:8080/  (Wi-Fi) in Safari
```

`make package` alone just builds `./packages/*.deb`. The package installs the agent to
`/Library/MobileSubstrate/DynamicLibraries/` and the web client to `/var/mobile/rctl/`,
shows up in Cydia as `com.greatlove.rctl`, and uninstalls cleanly.

> NOTE: the macOS `ldid` signature is rejected by on-device AMFI on arm64e, so the package's
> `postinst` re-signs the dylib with the device's own `ldid` (and resprings). The SSH targets
> are defined in `~/.ssh/config` (`rctl-device` = USB tunnel, `greatlove` = Wi-Fi).

## Roadmap

1. **P1 — done.** Screen capture + hardware H.264 + live stream to a browser over LAN.
2. **P2 — touch done.** Real touch control (`IOHIDEvent`), correct in all orientations.
   Remaining: keyboard input, and control inside 3rd-party apps.
3. **P3** — internet access: WebRTC transport + our own signaling + TURN relay.
4. **P4** — clipboard sync, file transfer, audio, autostart/persistence, auth & encryption.
```
