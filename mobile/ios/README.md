# iOS Controller

The iOS controller uses Swift 6 and SwiftUI for product UI, with UIKit-owned
WebRTC rendering, Picture in Picture, and lifecycle-sensitive media integration.
It does not wrap the browser UI in a WebView.

The checked-in modules are:

- `Modules/RctlProtocol`: bounded native models for the shared wire contracts;
- `Modules/RctlClient`: QR pairing validation, P-256 request proofs,
  Secure Enclave/Keychain identity, refresh credential storage, and relay auth;
- `Modules/RctlRealtime`: vendor-isolated signaling, PeerConnection lifecycle,
  bounded DataChannels, and Metal video rendering backed by an exact,
  checksum-verified XCFramework.

Run all modules through `make mobile-ios-test` from the repository root. A
non-shipping probe host is the next media-spike increment; the production
application host follows only after the real device path passes its gate.

Ordinary contributors should need Xcode and the repository only. The future app
uses a checked-in Xcode project plus local Swift packages; generated media
dependencies are fetched as checksum-verified immutable artifacts.

Build settings live in reviewed `.xcconfig` files, schemes and test plans are
shared, and automation calls `xcodebuild`. Bazel and project generators are not
required unless the measured project graph later crosses the migration criteria
in `docs/MOBILE-PLAN.md`.
