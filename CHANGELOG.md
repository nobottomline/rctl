# Changelog

## 0.3.1

- Fixed interactive `curl | sudo sh` setup by reconnecting the verified wizard
  to the controlling terminal and added visible lifecycle progress.
- Added a release-gated, P-256 signed stable device-update catalog with exact
  target and rollback package verification.
- Added update target awareness so already-current devices are not offered a
  redundant transaction.
- Documented the intentional unauthenticated trusted-LAN/USB local-control
  contract and added contributor navigation across runtime components.

## 0.3.0

- First qualified public package and self-hosted relay release.
