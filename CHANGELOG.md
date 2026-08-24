# Changelog

## Unreleased

## 0.3.3

- Added an administrator-controlled `LAN + Relay` / `Relay only` network policy.
  Relay-only mode binds the device API to loopback, requires an approved relay
  identity, uses confirmation-token mutations, and includes an SSH recovery path.
- Replaced opaque setup pauses with numbered, color-aware lifecycle progress,
  per-stage timing, terminal spinners, plain CI logs, and signal-aware
  cancellation that preserves rollback behavior.
- Reworked the project README around the verified one-command VPS setup and the
  public LAN-only package flow.

## 0.3.2

- Fixed interactive `curl | sudo sh` setup by reconnecting the verified wizard
  to the controlling terminal and added visible lifecycle progress.
- Added a release-gated, P-256 signed stable device-update catalog with exact
  target and rollback package verification.
- Added update target awareness so already-current devices are not offered a
  redundant transaction.
- Documented the intentional unauthenticated trusted-LAN/USB local-control
  contract and added contributor navigation across runtime components.
- Made release-signing key permission validation portable across GNU/Linux and
  BSD/macOS `stat` implementations.

## 0.3.0

- First qualified public package and self-hosted relay release.
