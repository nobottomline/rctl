# Native Direct-LAN Connection

Status: implemented in the iOS controller source. LAN and Relay have separate
entries on the Devices screen; LAN does not require a relay profile. Physical
controller qualification remains a release gate, as detailed below.

Bonjour discovery and a persistent LAN/Relay indicator are implemented alongside
the direct-IP flow. [Delivery and qualification](MOBILE-LAN-PLAN.md) track the
remaining physical matrix and the separate [authenticated pairing gate](../protocol/local-auth-v1.md).

## User Flow

Devices -> Nearby -> Find devices on this network opts into system Bonjour.
After opt-in, discovery runs only while Devices is visible and active. Select a
device, then explicitly open in View mode or save it. Selection re-resolves the
service and checks capabilities. Long-press -> Use for saved device opens the
existing editor with the new address; only Save and connect replaces the old
address. The saved UUID and custom name survive. Stop discovery and Add by
address remain available. Names and discovery records do not verify ownership.

LAN/Relay remains visible in all session states. Session Controls shows the
endpoint; LAN is described as trusted-network access, not authenticated pairing.

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

## Relay-only Policy And Discovery

The relay admin LAN switch calls the device's confirmed `POST /v1/local_access`.
A successful change persists the policy, immediately deregisters Bonjour and
cancels pending registration retries, then restarts the daemon. Relay-only
startup binds HTTP to loopback and does not register `_rctl._tcp`; the outbound
relay connection remains independent. Re-enabling LAN registers again after
restart. Rejected changes leave the current advertisement intact.

Startup registration finishes before the policy-changing REST handler becomes
reachable, preventing an early disable request from being overwritten by a
late startup registration. CLI `--local-access` only saves the policy and
requires the documented daemon restart before either binding or discovery
changes. Browsers may briefly retain a cached service; it must not be treated
as proof of reachability. Saved manual entries are not deleted when LAN is off.

Qualification (2026-09-10): rootful `0.3.4-18+debug` passed a confirmed API
cycle through LAN -> Relay-only -> LAN after safe deployment. The transition
reported discovery off immediately; after restart the loopback API remained
reachable while a direct LAN HTTP connection failed. Restoring the original
LAN policy restored direct HTTP and discovery advertising. This exercised the
same device API as the admin switch, not the production relay/browser path.
Native policy/discovery tests and both package builds passed. Rootless physical
discovery and the native controller's cache-removal behavior remain unqualified.

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
Bonjour selects private IPv4 only because the daemon listener is AF_INET. TXT
is capped at 400 bytes, results at 64, interfaces/addresses at eight and concurrent
resolutions at four with a five-second per-service deadline. DNS-only resolution
validates and pins the literal before any application TCP connection.

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

The app declares `NSLocalNetworkUsageDescription`, `NSBonjourServices` and
`NSAppTransportSecurity.NSAllowsLocalNetworking`, without arbitrary-load or TLS
bypass exceptions. Discovery is explicit opt-in. Access starts on add/connect or returning to
an already opened remote view. Local-network permission and App Transport
Security are separate mechanisms.

Verified on 2026-09-10:

- Private-address normalization, exact-target WS policy, isolated credential
  storage, redirect refusal, and host-only ICE policy pass package tests.
- App tests cover multiple same-port devices, persistence/deduplication,
  malformed saved data, cancellation, oversized/malformed/incompatible
  capabilities, and HTTP errors. Relay lifecycle regression tests still pass.
- Discovery byte fixtures, malformed/oversized records, duplicate keys,
  protocol versions, service identity and cancellation pass package tests.
  Native tests cover registration, stop, responder failure, retry and stale-retry
  cancellation. App tests cover immutable access path, opt-in without background
  browsing, confirmed address replacement and the four-request probe budget.
- The rootful package was installed through `scripts/deploy.sh`, with SpringBoard
  IPC verified. Live Mac NWBrowser/resolution/capabilities passed. Repeated
  add/remove events on this LAN remain a sleep/network qualification gap.
  Rootless build and public-artifact audit passed, not rootless runtime discovery.
- iOS 18.6 and 26.1 Simulator received real H.264 video from a rootless iPad via
  local HTTP/WS and restored video after suspend/resume. No relay profile or
  relay request was needed. This is not physical-controller permission testing.

Ordinary `make mobile-test` does not contact a physical device. To opt into the
view-only live test, set `RCTL_LAN_TEST_ADDRESS` to an owned device's private
address before running `make mobile-ios-app-test`. `RCTL_IOS_TEST_RUNTIME` may
select an installed runtime version, such as `18.6`; otherwise the newest
installed iOS 16+ runtime is selected. The test runner creates and deletes only
its own temporary simulator and passes no address into source or build settings.

For DNS-SD qualification on the Mac, explicitly set `RCTL_DISCOVERY_TEST_NAME`
to an owned device's advertised service name and run
`swift test --package-path mobile/ios/Modules/RctlRealtime --filter liveBonjourWhenExplicitlyConfigured`.
That opt-in test browses, resolves and reads capabilities only; it does not
start media or send input. Without the variable it is skipped.

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
