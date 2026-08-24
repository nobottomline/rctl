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

`RctlMobile.xcodeproj` is the checked-in application graph. Its shared
`RCTL MediaProbe` scheme hosts the non-shipping physical-device qualification
app in `MediaProbe/`. Run package tests with `make mobile-ios-test`, build the
app with `make mobile-ios-build`, or run both with `make mobile-test`.

Apple signing is machine-local. Copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` and set `DEVELOPMENT_TEAM`, or select a team in Xcode
and move the resulting value into that ignored file. Never commit a personal
team identifier or provisioning material. Product identifiers use the
`com.greatlove.rctl` namespace; `nobottomline` is reserved for GitHub and GHCR
coordinates.

Ordinary contributors need Xcode and the repository only. The project consumes
local Swift packages; the sole generated media dependency is fetched at an
exact revision as a checksum-verified immutable artifact. No relay origin,
pairing payload, controller credential, signing identity, or captured media is
stored in the project.

Build settings live in reviewed `.xcconfig` files, schemes and test plans are
shared, and automation calls `xcodebuild`. Bazel and project generators are not
required unless the measured project graph later crosses the migration criteria
in `docs/MOBILE-PLAN.md`.
