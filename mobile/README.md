# Native Mobile Controllers

`mobile/` contains the native controller work for iOS and Android. They are
independent products in the rctl monorepo and consume the versioned contracts
in `protocol/`. The iOS protocol, identity, realtime modules, and MediaProbe are
implemented; neither mobile controller is a shipping product yet.

- `ios/`: Swift/SwiftUI application, UIKit-hosted realtime media surfaces, and
  local Swift packages.
- `android/`: Kotlin/Compose application with Android View-hosted realtime media.

Read `docs/MOBILE.md` for architecture and `docs/MOBILE-PLAN.md` for delivery
order and qualification gates. `docs/MOBILE-DESIGN.md` defines the shared
product behavior and the platform-native visual direction.

Mobile builds are not part of the device `.deb` build. Never commit signing
identities, provisioning profiles, keystores, relay origins, pairing payloads,
controller credentials, captured media, or production diagnostics.
