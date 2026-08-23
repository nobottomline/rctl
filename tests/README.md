# Native Host Tests

These tests exercise shared C++/Objective-C++ logic on macOS without injecting
an iOS process. The root `make test` target builds and runs the supported set.

Host tests are fast contract checks, not device-runtime proof. Camera, audio,
input, process lifecycle, relay reconnect, and rollback changes still require
the physical-device qualification described in the feature documents.
