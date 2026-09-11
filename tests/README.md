# Native Host Tests

These tests exercise shared C++/Objective-C++ logic on macOS without injecting
an iOS process. The root `make test` target builds and runs the supported set.

Host tests are fast contract checks, not device-runtime proof. Camera, audio,
input, process lifecycle, relay reconnect, and rollback changes still require
the physical-device qualification described in the feature documents.

`bash scripts/test-webrtc-ownership.sh` separately builds the pinned
libdatachannel for macOS and tests the production session registry with real
PeerConnections. It needs CMake, Homebrew OpenSSL 3 and Opus, and the sources
populated by `make deps`. It checks owner-scoped cleanup, retained worker
references, incomplete routes, repeated disconnect and preservation of LAN and
other relay sessions. It never installs a package or captures device media.
