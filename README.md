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
├── docs/           # design & operational docs
└── scripts/        # build / deploy helpers
```

Planned, not yet created: `relay/` (Go signaling + TURN), `ios-app/` (native client),
`proto/` (shared protocol). The HTTP server lives in the SpringBoard agent today for
simplicity; it may later move into a separate root daemon (so a network bug can't respring
SpringBoard).

## Transport / decode decision

- **Decode: WebCodecs** (frame-level, low latency) — the client decoder, kept long-term.
- **Transport now (LAN/dev): HTTP chunked** — simple, good enough on a local network.
- **Transport for internet (P3): WebRTC** — DataChannel carrying encoded frames + WebCodecs
  decode (lowest latency, full control), with ICE/STUN/**TURN** for NAT traversal. On-device
  WebRTC via **libdatachannel** (lightweight) rather than libwebrtc. Signaling = small Go server.

## Build & deploy

Requires Theos (`$THEOS`) and the iOS 14.5 SDK on macOS. Passwordless SSH alias `greatlove`.

```sh
make -C springboard THEOS=/Users/grigorij/theos
scp -q springboard/.theos/obj/debug/rctlsbcap.dylib \
    greatlove:/Library/MobileSubstrate/DynamicLibraries/rctlsbcap.dylib
ssh greatlove 'ldid -S /Library/MobileSubstrate/DynamicLibraries/rctlsbcap.dylib; killall SpringBoard'
# web client (served from disk, no rebuild needed to iterate):
scp -q web/index.html greatlove:/var/mobile/rctl/index.html
# then open http://<ipad-ip>:8080/ in Safari (WebCodecs required)
```

> NOTE: the macOS `ldid` signature is rejected by on-device AMFI — always re-sign on the
> device (`ldid -S`) after copying, or the binary is SIGKILLed at launch.
>
> When Wi-Fi is flaky, work over USB: `iproxy 2222:22 8080:8080` then `ssh -p 2222 root@localhost`
> and `curl http://localhost:8080/…` (and open the page from the Mac at `http://localhost:8080/`).

## Roadmap

1. **P1 — done.** Screen capture + hardware H.264 + live stream to a browser over LAN.
2. **P2 — touch done.** Real touch control (`IOHIDEvent`), correct in all orientations.
   Remaining: keyboard input, and control inside 3rd-party apps.
3. **P3** — internet access: WebRTC transport + our own signaling + TURN relay.
4. **P4** — clipboard sync, file transfer, audio, autostart/persistence, auth & encryption.
```
