# Native Direct-LAN Connection

Status: design and implementation gates; not implemented in the shipping iOS
controller source. The current app still requires a paired relay profile.

## User Flow

Add device -> Local network -> enter an address and optional name -> Connect.
The default port is 8080. A public LAN-only package is sufficient: no VPS,
domain, certificate provisioning, enrollment, or relay controller account is
required. Save the address locally for the next connection. Start in View mode;
control remains an explicit operator action.

Two devices can both use port 8080 because their addresses differ. A router's
DHCP change can invalidate a saved address; provide an Edit address action, not
automatic reconnection to an unrelated host or a subnet scan. A display name or
HTTP capabilities response is not cryptographic device authentication.

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

The initial address form should accept validated private IP literals and a
valid port, rejecting credentials, arbitrary paths, query strings, fragments,
public destinations, multicast and broadcast. Support bracketed IPv6 where
qualified; explicitly report unsupported link-local zone identifiers rather
than guessing the interface. Hostname/Bonjour discovery can follow later with
resolved-address validation and permission tests; it is not required for the
first complete LAN path.

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

Declare `NSLocalNetworkUsageDescription` and initiate access only after Connect.
Local-network permission and App Transport Security are separate mechanisms;
verify the narrow ATS configuration for HTTP and WebSocket IP connections on
iOS 16, iOS 17+, and the current supported release. Apple's version-specific
rules do not justify a global `NSAllowsArbitraryLoads` exception.

Required checks before declaring LAN complete:

- Public rootful and rootless packages connect without a relay configuration.
- Screen, four orientations, input, and reconnect work through the native app.
- Two devices with the same port remain separate saved targets.
- Relay credentials never appear in local HTTP or WebSocket requests.
- Redirects and non-local targets fail closed; HTTP timeouts/body sizes are bounded.
- Denied permission, offline address, incompatible protocol, and Relay-only mode
  produce actionable errors without guessing the cause of a generic timeout.
- An isolated LAN works without WAN, STUN, TURN, or an available VPS.
- Wi-Fi loss, cancellation, profile changes and backgrounding stop the session;
  recovery does not restore Control mode without an explicit action.
- Existing HTTPS/WSS relay behavior and profile persistence remain unchanged.

References: [Apple local-network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
and [ATS local networking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).
