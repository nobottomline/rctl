# third_party/webrtc

The WebRTC transport stack `rctld` links, cross-compiled for iOS as static
libraries. The daemon uses it for **both** modes:

- **Local (public build):** direct-LAN WebRTC P2P between the browser and the
  device — an RTP H.264 video track plus control/audio/file DataChannels.
- **Relay (personalized build):** the same peer connection, signalled through
  your self-hosted relay.

So these libraries are **required for every build**, including the public
LAN-only tweak — there is no non-WebRTC fallback path.

## Building

From the repo root, once, before `make package`:

```sh
make deps
```

That runs [`build-ios.sh`](./build-ios.sh), which fetches and compiles each
dependency at a pinned version into `.lib/` (gitignored). Re-running is cheap:
prebuilt dependencies are skipped.

### Requirements

- Xcode with the iphoneos SDK (`xcode-select --install` is not enough)
- `cmake` and `ninja` (`brew install cmake ninja`)
- Python modules `jsonschema` + `jinja2` for Mbed TLS codegen (the script
  attempts `pip install` automatically)

## Pinned versions

| Dependency      | Pin                              | Why |
|-----------------|----------------------------------|-----|
| libdatachannel  | `a542d870` (master commit)        | needed master fixes for media + the Mbed TLS engine; no tagged release has them yet |
| Mbed TLS        | `mbedtls-3.6.6` (LTS tag)         | DTLS / DTLS-SRTP |
| libopus         | `v1.5.2`                          | audio encoder for the captured-PCM Opus track |

libdatachannel's own deps (libsrtp, libjuice, usrsctp, plog, json) come in as
its git submodules, so they are transitively pinned by the commit above. Every
pin is an exact commit or release tag, so `make deps` is fully reproducible.

## Why pinned-source instead of vendored binaries

End users install a prebuilt `.deb` from the releases page and never build this.
Only contributors run `make deps`, and they already have a build toolchain — so
we build from pinned upstream sources (reproducible, auditable, no multi-megabyte
binary blobs committed to git) rather than checking in the `.a` files.
