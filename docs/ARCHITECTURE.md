# rctl — Architecture

## 1. Goal

Fully control a jailbroken iPad remotely: see the live screen and inject input, with
latency low enough to feel direct (target < 100 ms glass-to-glass on LAN), reachable from
a browser or a native iOS app, on LAN today and over the internet later.

## 2. High-level design

`rctl` follows the *scrcpy* model: a lightweight server on the controlled device captures
and hardware-encodes the screen, streams it to a client, and the client streams input
events back, which the server injects as real HID events.

```
┌──────────────────────────────┐                 ┌───────────────────────────┐
│  iPad (jailbroken, root)      │                 │  Client (browser / iOS)   │
│  ── rctld (launchd daemon) ── │                 │                           │
│                               │   video (RTP)   │  decode (WebCodecs/VT)    │
│  capture ─► VideoToolbox enc ─┼────────────────►│  render                   │
│                               │                 │                           │
│  IOKit HID inject ◄───────────┼─────────────────┤  pointer / key events     │
│  files / clipboard            │   control (DC)  │  file & clipboard UI      │
└───────────────┬───────────────┘                 └─────────────┬─────────────┘
                └────────────── transport (WebRTC) ─────────────┘
        LAN-direct during dev → signaling + TURN relay for internet
```

## 3. On-device daemon (`rctld`)

A **standalone root `launchd` daemon**, deliberately *not* a MobileSubstrate tweak: it does
not need to be injected into another process, which avoids the `arm64e` injection
complexity on the A12 and keeps it a clean, self-contained service. Built with Theos
(`TARGET := iphone:clang:14.5:14.0`, `ARCHS := arm64 arm64e`), ad-hoc signed with `ldid`,
entitlements added as required by the private frameworks it touches.

Modules:

- **Capture.** Acquire the framebuffer as an `IOSurface`. Candidate paths, in order of
  preference: `CARenderServerRenderDisplay` / `CARenderServerRenderLayerWithTransform`
  rendering the system layer tree into an `IOSurface`, or direct
  `IOMobileFramebuffer` surface access. Driven off a `CADisplayLink`-equivalent tick on a
  dedicated thread; no work on the main thread; no busy-waiting.
- **Encode.** `VideoToolbox` hardware encoder (H.264 baseline/main first for universal
  client decode; HEVC as an option for the native client). Real-time settings, periodic
  keyframes, bitrate adapted to the channel.
- **Input injection.** `IOKit` `IOHIDEvent` digitizer events posted to the HID event
  system (reference implementations: `xuan32546/IOS13-SimulateTouch`, julioverne's
  `SimulateTouch`). Covers touch, multitouch, and the hardware buttons; keyboard via
  keyboard HID usages.
- **Files / clipboard.** Direct root filesystem access for transfer; pasteboard bridge for
  clipboard sync.
- **Session/control.** Connection management, authentication, and the control channel.

## 4. Transport

- **WebRTC** for both media (encoded video over RTP/SRTP) and a reliable/unreliable data
  channel for control, files, and clipboard. DTLS-SRTP gives end-to-end encryption.
- **LAN-direct** during development (the daemon offers a local signaling endpoint).
- **Internet** via our own **signaling server + TURN relay** (`relay/`, Go): P2P when NAT
  traversal succeeds, relayed otherwise. A mesh VPN (e.g. WireGuard-based) is a fallback
  option but the goal is a self-contained, zero-dependency relay.

## 5. Clients

- **Web client** (`web/`): WebRTC + `WebCodecs`/`<video>`, runs in any browser including
  Safari on a non-jailbroken iPhone — zero install. Built first for fast iteration.
- **Native iOS client** (`ios/`): the flagship — `VideoToolbox` hardware decode + Metal
  rendering for the lowest latency, signed with the user's Apple Developer account.

## 6. Security

A root daemon that accepts control over the network is a large attack surface and is
treated as security-critical from the start:

- mandatory authentication (per-device key / pairing), no anonymous control;
- all transport encrypted (DTLS-SRTP / TLS);
- bind to loopback/LAN until pairing is configured; explicit opt-in for internet exposure.

## 7. Operational constraints

- unc0ver is **semi-untethered**: a full reboot drops the jailbreak and the daemon until
  the unc0ver app is reopened on-device. Unattended use therefore requires the iPad to stay
  powered and not reboot. Resprings are survivable; the daemon must auto-start on respring.

## 8. Roadmap

1. **P1** — capture + H.264 encode + stream to browser over LAN (view only).
2. **P2** — touch injection from the client (real control).
3. **P3** — internet access via signaling + TURN relay.
4. **P4** — keyboard, clipboard, file transfer, audio, autostart, auth & encryption.
