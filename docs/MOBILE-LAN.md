# Native Direct-LAN Connection

Status: implemented in the iOS controller source. LAN and Relay have separate
entries on the Devices screen; LAN does not require a relay profile. Physical
controller qualification remains a release gate, as detailed below.

Next increments: [LAN discovery, persistent access-mode UI, and authenticated
pairing design](MOBILE-LAN-PLAN.md). These are planned separately from the
implemented direct-IP flow.

## User Flow

Devices -> Add Local Device -> enter an address and optional name -> Connect.
The default port is 8080. A public LAN-only package is sufficient: no VPS,
domain, certificate provisioning, enrollment, or relay controller account is
required. Save the address locally for the next connection. Start in View mode;
control remains an explicit operator action.

Two devices can both use port 8080 because their addresses differ. A router's
DHCP change can invalidate a saved address; provide an Edit address action, not
automatic reconnection to an unrelated host or a subnet scan. A display name or
HTTP capabilities response is not cryptographic device authentication. Swipe or
long-press a saved entry to edit or remove it. Removal only forgets the address;
it does not uninstall or reconfigure the controlled device. Up to 64 addresses
are stored, with duplicate endpoints retaining their original entry identity.

Internet service is unnecessary, but the devices need a reachable network path.
Guest Wi-Fi/client isolation, firewall rules, VPN routing, denied local-network
permission, and the daemon's explicit Relay-only policy can prevent access even
when the devices appear to share Wi-Fi. Do not infer reachability from the SSID.

## Existing Device Path

- `GET /v1/capabilities` describes the daemon and protocol compatibility.
- `GET /ws/signal` upgrades to a device-owned signaling WebSocket.
- `core/net/Term.mm` opens a screen session with an empty ICE server list and
  forwards the existing signaling envelopes. The device remains the offerer.
- The existing native realtime implementation already handles an offer without
  a preceding relay `ready` message and can create a host-only PeerConnection.
- H.264, video geometry, state, input, and lifecycle stay in `RctlRealtime`; no
  duplicate local video engine or daemon implementation is needed.

Do not fabricate a relay `ControllerDevice` to represent a local connection.
Its approval, controller scopes, online state, and `controller.scoped_sessions`
gate belong to relay authorization. Local preflight uses the real daemon
capabilities and the existing trusted-LAN policy instead.

## Boundaries

Keep relay profiles and local addresses distinct in the app's connection model.
A connection-specific signaling builder creates either a signed relay request
or a credential-free local request, then hands it to the same realtime session.
No relay token, signature, refresh request, cookie, or enrollment material may
reach the local endpoint. Use an isolated, non-caching URLSession without shared
cookie/credential storage and reject redirects during preflight/signaling.

`LocalDeviceAddress` accepts RFC1918 IPv4 and bracketed IPv6 ULA literals, with
an optional port (1-65535) and optional `http://` prefix. It rejects credentials,
paths other than `/`, query strings, fragments, ambiguous IPv4 notation, public
destinations, multicast, limited broadcast, loopback, hostnames, and link-local
addresses. ULA parsing is unit-tested; end-to-end IPv6 remains unqualified.
Hostname/Bonjour discovery requires resolved-address validation and permission
tests and is intentionally not part of this slice.

`LocalDeviceClient` fetches capabilities with a 64 KiB streaming receive limit,
15-second request and 20-second resource timeouts, and cancellable URLSession
tasks. It checks daemon identity, protocol compatibility, and the selected media
feature before opening signaling. The realtime session permits plaintext only
for the exact validated local signaling endpoint, uses isolated storage, and
rejects nonempty ICE server lists in LAN mode. No STUN/TURN service is required.

`LocalDevicesModel` stores only names, UUIDs and validated addresses under
`rctl.controller.local-devices.v1`, separately from the relay profile and
Keychain. Saved data is size-limited and revalidated on load. Pending additions
cannot persist after cancellation or a competing list mutation. Leaving the
remote view, backgrounding or changing media cancels pending connection
preparation. Reconnect always returns to View mode.

Plaintext HTTP/WS permission must be tied to the explicit local connection mode
and validated target. Do not make the existing WSS validator accept every `ws`
URL, and never fall back from failed relay authentication to LAN automatically.
Do not disable TLS certificate validation or introduce global arbitrary loads.

The existing local API is unauthenticated. WebRTC encrypts media/data, but
plaintext signaling does not establish a trusted device identity against an
active LAN attacker. Describe this as trusted-network access, not equivalent
security to authenticated relay access. Do not expose port 8080 on the internet.
Authenticated local pairing is a separate future protocol change.

## iOS Integration And Qualification

The app declares `NSLocalNetworkUsageDescription` and
`NSAppTransportSecurity.NSAllowsLocalNetworking`, without arbitrary-load or TLS
bypass exceptions. Access starts only on explicit add/connect or returning to
an already opened remote view. Local-network permission and App Transport
Security are separate mechanisms.

Verified on 2026-09-10:

- Private-address normalization, exact-target WS policy, isolated credential
  storage, redirect refusal, and host-only ICE policy pass package tests.
- App tests cover multiple same-port devices, persistence/deduplication,
  malformed saved data, cancellation, oversized/malformed/incompatible
  capabilities, and HTTP errors. Relay lifecycle regression tests still pass.
- iOS 18.6 and 26.1 Simulator received real H.264 video from a rootless iPad via
  local HTTP/WS and restored video after suspend/resume. No relay profile or
  relay request was needed. This is not physical-controller permission testing.

Ordinary `make mobile-test` does not contact a physical device. To opt into the
view-only live test, set `RCTL_LAN_TEST_ADDRESS` to an owned device's private
address before running `make mobile-ios-app-test`. `RCTL_IOS_TEST_RUNTIME` may
select an installed runtime version, such as `18.6`; otherwise the newest
installed iOS 16+ runtime is selected. The test runner creates and deletes only
its own temporary simulator and passes no address into source or build settings.

Remaining checks before declaring the LAN slice release-qualified:

- Public rootful and rootless packages connect without a relay configuration.
- Screen, four orientations, input, and reconnect work through the native app.
- Validate physical Local Network permission allow/deny and IP-based HTTP/WS
  on the minimum supported iOS 16, iOS 17, and current iOS.
- Qualify an IPv6 ULA network on physical devices before advertising IPv6.
- Denied permission, offline address, incompatible protocol, and Relay-only mode
  produce actionable errors without guessing the cause of a generic timeout.
- An isolated LAN works without WAN, STUN, TURN, or an available VPS.
- Wi-Fi loss, cancellation, profile changes and backgrounding stop the session;
  recovery does not restore Control mode without an explicit action.
- Exercise a real relay profile alongside saved LAN devices, including resetting
  that profile, without invalidating or reconnecting the unrelated LAN session.

References: [Apple local-network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
and [ATS local networking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).
