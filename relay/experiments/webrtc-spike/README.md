# WebRTC DataChannel spike (Phase 2)

Proves the transport we'll later run via **libdatachannel inside `rctld`**:
a browser `RTCPeerConnection` talking to a native libdatachannel peer over an
**unreliable, unordered `video` DataChannel** (`maxRetransmits=0`) plus a
reliable `control` channel. This is the internet-video transport that replaces
the current TCP/WebSocket relay path (which head-of-line-blocks and freezes).

The **local LAN HTTP/WebCodecs path is untouched** — WebRTC is only for the
internet/relay path.

## Result (proven on macOS)

- libdatachannel builds cleanly on macOS (OpenSSL@3). ✓
- Browser ⇆ native libdatachannel connect over the unreliable `video` channel. ✓
- ~60 fps synthetic frames, **one-way latency ~1 ms** (p95/max 1–2 ms) on
  localhost; `control` channel established both ways. ✓

(Loss/jitter benefit — where unreliable beats reliable — is the next step,
measured under Network Link Conditioner; on a lossless localhost there's nothing
to drop, so out-of-order/gaps read 0.)

## Layout

- `native_peer.cpp` — stand-in for rctld's device side (libdatachannel answerer,
  streams synthetic timestamped frames).
- `web/index.html` — browser peer (offerer); measures one-way latency, fps,
  out-of-order and gaps.
- `signal_server.go` — minimal 2-peer signaling relay + static server (stands in
  for the relay's `/signal` endpoint until Phase 2.5).
- `build.sh` — compiles `native_peer` against the locally-built library.
- `.lib/` (gitignored) — the cloned + built libdatachannel.

## Run

```bash
# 1) build libdatachannel once
mkdir -p experiments/webrtc-spike/.lib && cd experiments/webrtc-spike/.lib
git clone --recurse-submodules --shallow-submodules --depth 1 \
  https://github.com/paullouisageneau/libdatachannel.git
cd libdatachannel
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DUSE_GNUTLS=0 -DUSE_NICE=0 \
  -DNO_TESTS=1 -DNO_EXAMPLES=1 -DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl@3
cmake --build build

# 2) build the native peer
cd ../../ && bash build.sh

# 3) run (from the relay/ dir, three terminals)
go run experiments/webrtc-spike/signal_server.go     # signaling + page on :8099
experiments/webrtc-spike/native_peer                 # restart per browser session
# open http://localhost:8099  (browser must connect AFTER native is waiting)
```

Note: the native peer uses a single-use PeerConnection — restart it for each new
browser session. On localhost, Chrome mDNS-obfuscates its own host candidates,
but the native's real host candidates let the browser connect; ICE candidates
must be queued until the answer is applied (see `index.html`).

## Phase 3 — iOS cross-compile (proven)

`build-ios.sh` cross-compiles the whole stack to **fat arm64 + arm64e, deployment
target iOS 13.0** (built against the Xcode iPhoneOS SDK; minos 13.0 ⇒ runs on the
iPad's iOS 14.4 and future iOS 15/17 devices, arm64 or arm64e). The high-risk
step is de-risked — all static libs rctld needs build:

- `libdatachannel.a`, `libjuice.a` (ICE), `libusrsctp.a` (SCTP) — arm64 + arm64e
- `libmbedtls.a` + `libmbedcrypto.a` + `libmbedx509.a` (DTLS) — arm64 + arm64e

(The daemon itself is arm64-only today — arm64 runs on arm64e devices in
compatibility — so the arm64e slice is insurance for a future native arm64e
daemon, not a requirement.)

Gotchas (baked into `build-ios.sh`): iOS has no system OpenSSL → use **mbedtls**;
mbedtls codegen needs Python `jsonschema`+`jinja2`; **enable `MBEDTLS_SSL_DTLS_SRTP`**
(libdatachannel's mbedtls path references the SRTP profile symbols even with
`NO_MEDIA`); when cross-compiling set `CMAKE_FIND_ROOT_PATH` to the mbedtls
install or `find_library` won't see it.

## Phase 2.5 — through the real relay signaling (proven)

`relay_device.cpp` is the DEVICE side (the future rctld logic, developed on
macOS): it connects to the relay's `/device` websocket as a device and handles
the multiplexed `webrtc_signal` envelopes (`open`/`offer`/`candidate`/`close`),
one libdatachannel PeerConnection per session. Verified end-to-end:

```
browser  ──/signal/devices/{id}──▶  relay  ──webrtc_signal──▶  relay_device (libdatachannel)
```

A browser (offerer) connecting to the relay's `/signal/devices/{id}` established
the unreliable video channel through the **real relay signaling code** and
streamed at **~0–3 ms latency, 0 loss**. So the relay's signaling design is
validated, and `relay_device.cpp` is the blueprint for the rctld integration.

Test recipe: run relay with `RCTL_RELAY_ENABLE_WEBRTC=1 RCTL_RELAY_ALLOW_INSECURE=1`,
enroll+approve a device, start `relay_device ws://host/device <token> <id> <name>`,
then from the relay origin open `/signal/devices/<id>` and offer.

## Next

- Phase 4: port `relay_device.cpp` into `rctld` (via git-patch); link the iOS
  libs; feed real H.264 AUs (from the local capture pipeline) onto the video
  channel; browser keyframe/drop rules + WebCodecs decode.
- Phase 5: TURN (coturn) for hard NATs + connection-type display in admin.
- Optional: loss/jitter test (Network Link Conditioner) to visually confirm
  unreliable beats reliable.
