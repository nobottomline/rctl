# Native Mobile Controllers

`mobile/` contains the planned native iOS and Android controller applications.
They are independent products in the rctl monorepo and consume the versioned
contracts in `protocol/`.

- `ios/`: Swift/SwiftUI application, UIKit-hosted realtime media surfaces, and
  local Swift packages.
- `android/`: Kotlin/Compose application with Android View-hosted realtime media.

Read `docs/MOBILE.md` for architecture and `docs/MOBILE-PLAN.md` for delivery
order and qualification gates.

Mobile builds are not part of the device `.deb` build. Never commit signing
identities, provisioning profiles, keystores, relay origins, pairing payloads,
controller credentials, captured media, or production diagnostics.
