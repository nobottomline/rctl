# LAN Plan Review

Reviewed 2026-09-10 against the current checkout. This is a design review, not
an exploitation test or a claim that runtime vulnerabilities were fixed.
The resulting implementation plan is [MOBILE-LAN-PLAN.md](MOBILE-LAN-PLAN.md).

## Evidence And Recommendation

I inspected both supplied plans and the listener, direct signaling, file
download, device policy, controller key storage, and dependency build code.
We can retain the detailed UX and independently deliverable increments from
the larger draft while correcting its trust assumptions. The smaller draft
has stronger boundaries, but also misses the pairing-screen exposure and leaves
resolution, acceptance criteria, and migration less concrete.

While this review was in progress, commit `8b5bdaf` introduced a newer combined
plan. It already fixed explicit address confirmation and moved more operations
under a protected channel. I re-read that revision and applied the remaining
corrections without replacing its useful UX/policy structure. The signaling-only
critique below refers to the original detailed draft; the newer custom-channel
proposal still needed bootstrap, cryptographic review and lifecycle decisions.

The original drafts are retained unchanged as evidence, not competing active
implementation specifications:

- [Detailed draft](MOBILE-LAN-PLAN-CLAUDE.md), SHA-256
  `0f9596e053973ed0d365fc134ef8c2c3cdca89b3a32737acd5174f42f903b8e1`.
- [Boundary-first draft](MOBILE-LAN-PLAN-CODEX.md), SHA-256
  `214768e9298e8cfb88f16676ba7b949c66a6ed13f36aae8f7104bd34e86accbc`.

## Blocking Design Issues

### Pairing Cannot Assume The Screen Or Root-Owned Files Are Private

The detailed draft excludes attackers who can see the iPad screen or read
root-owned files. However, `core/net/HttpStreamServer.mm:handle_client` exposes
`/stream`, `/ws/signal`, `/ws/term`, and `/v1/pull_stream` through the current
trusted-LAN listener. `stream_file_download` opens a supplied path as the daemon;
filesystem mode 0600 alone does not stop that root process reading its own key.
The QR ceremony therefore cannot safely start by displaying a secret while
legacy sessions and endpoints remain available to the same network attacker.

We must close both new and already-open untrusted capture, control, file, and
terminal paths before displaying pairing material or persisting a new secret
key. A route-level check after WebSocket upgrade is too late. Existing remote
input must not be able to press Allow. Trusted bootstrap needs an explicit
policy transition and recovery, not a temporary overlay. Neither plan fully
specified this. This is a protocol prerequisite, not an accusation that today's
explicitly trusted-LAN product promised hostile-network protection.

### Advertised Identity Cannot Authorize Silent Address Replacement

The detailed draft proposes reusing relay DeviceID in TXT, deduplicating by it,
and silently updating saved addresses after matching capabilities.device.id.
An attacker can copy both unsigned values. The consistency check can detect
accidental stale data but cannot establish ownership or justify unattended
retargeting. It also broadcasts a cross-context identifier unnecessarily.

We keep local profile UUIDs and explicit address changes for unpaired devices.
After authenticated pairing, a changed address is accepted only after proving
the pinned device key. Discovery identifiers, if introduced later, remain
hints separate from relay credentials and persistent identity.

### Sealing Only Signaling Leaves Other HTTP Traffic Exposed

The detailed draft derives a custom ECDH/HKDF/GCM protocol and concludes local
TLS is unnecessary. Even assuming its signaling protocol were correct, signed
REST requests do not encrypt files, command bodies, or management responses.
The draft does not define equivalent protection for these paths, authenticated
server time, or robust domain separation from relay proofs.

We prefer a standard encrypted transport with pairing-anchored device trust.
TLS must be prototyped with changing IPs, WebSockets, and the iOS 14 daemon;
browser trust UX is a real cost, not solved by accepting arbitrary certificates.
A reviewed Noise/PAKE-based alternative remains possible if a concrete platform
constraint rules out TLS, but then every protected path needs defined framing
and resource limits. A bespoke composition of strong primitives is not an
approved protocol merely because Mbed TLS is already linked.

### Bounded Replay State Must Fail Closed At Capacity

The proposed 512-entry nonce cache can forget valid nonces while requests are
still inside the 300-second acceptance window. If full means evict oldest,
captured requests can become acceptable again. Capacity, session restart,
expiry, and overflow behavior need explicit rules: reject excess work or use a
reviewed bounded session/challenge scheme, never silently evict live protection.

Likewise, an unauthenticated new pairing request must not replace the active
owner ceremony. Per-IP limits alone do not prevent repeated cancellation by
multiple sources. Owner-opened bounded windows, busy responses, exact grants,
and abuse tests belong in the protocol design.

## Correctness And Scope Corrections

| Draft assumption | Correction in the consolidated plan |
| --- | --- |
| Connect with NWConnection, then check the resolved IP | Resolve DNS-SD records and addresses first; validate before opening an application TCP connection. Otherwise a forged service can cause a connection to a forbidden destination before rejection. |
| Accept ULA immediately | The daemon listener is AF_INET. Qualify dual-stack separately; a Swift parser is not IPv6 server support. |
| Manual entry solves client isolation or USB tunnels | It solves blocked multicast only if unicast is reachable. Client isolation can block both. Current native address policy rejects localhost, so ordinary iproxy on a Mac is not an implemented iPhone-controller path. |
| DNSServiceUpdateRecord renames the service | It updates records such as TXT. Changing the instance name requires an appropriate registration lifecycle; default to a generic non-personal name. |
| Discovery means Online | Show Discovered until bounded preflight succeeds. Neither state means authenticated. |
| Last IPv4 octet distinguishes duplicates | Show full address and port; different subnets can share the same last octet. |
| Header must include full address and ICE diagnostics | Keep a stable LAN/Relay badge; put long endpoints and optional diagnostics in session details to avoid cramped headers. |
| srflx is a separate access mode | It is an ICE candidate type. Auth/signaling mode and direct/TURN media route are separate dimensions. |
| Both increments reserve protocol 1.2 | Current version is 1.1; allocate versions when contracts land, accounting for parallel work. Discovery need not change capabilities at all. |
| Scope injection is only a codec layer | The WebSocket handshake must establish a principal; server-derived scopes, protected REST dispatch, revocation and session closure are authorization changes. |
| `/v1/local/access` already exists | The actual route is `/v1/local_access`. Reuse it deliberately or version an explicit replacement. |
| Secure Enclave is guaranteed | The existing signing-key abstraction supports a software fallback. Document and test the actual policy rather than claiming all stored keys are hardware-backed. |
| Loopback NWListener proves Bonjour visibility | Existing tests exercise loopback WebSocket transport, not real network discovery. Use deterministic discovery adapters plus isolated responder and physical-network qualification. |

We also do not add an embedded UDP-5353 responder as an automatic fallback.
That introduces multicast routing, conflict resolution, privacy, power, and
maintenance work. Manual IP remains the fallback while system DNS-SD failures
are diagnosed on the target jailbreak.

## What We Retain

The detailed draft's useful contributions are explicit empty/denied/incompatible
states, TXT fixtures and byte limits, compatibility migration tests, a connection
details view, cancellation on backgrounding, controller revocation, and concrete
physical qualification. The boundary-first draft contributes isolated LAN
credentials, minimal advertisements, explicit selection, no silent downgrade,
and separate authentication review. The consolidated plan combines these without
making discovery depend on cryptography or protocol-version reservations.

No live QR, file access, key extraction, network attack, or policy change was
performed during this review. Tests must use synthetic secrets and fixtures.
Current unauthenticated access must never be presented as safe on hostile LANs;
pairing cannot repair a device already compromised through prior open access.

## References

- [Apple DNS-SD resolution](https://developer.apple.com/library/archive/documentation/Networking/Conceptual/dns_discovery_api/Articles/resolving.html)
- [Apple DNS-SD API declarations](https://github.com/apple-oss-distributions/mDNSResponder/blob/main/mDNSShared/dns_sd.h)
- [RFC 6763: DNS-Based Service Discovery](https://www.rfc-editor.org/rfc/rfc6763.html)
- [TLS 1.3](https://www.rfc-editor.org/rfc/rfc8446.html)
