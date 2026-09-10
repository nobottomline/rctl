# Local Authentication: Transport Decision And Remaining Gate

Status: proposed architecture, not a wire contract or released authentication
feature. Reviewed baseline: 2026-09-10. Discovery and the access-path indicator
are independent of this gate; see [discovery-v1.md](discovery-v1.md) and
[the delivery plan](../docs/MOBILE-LAN-PLAN.md).

## Decision So Far

Use standard TLS as the leading transport candidate. Do not implement the
archived custom ECDH/HKDF/AEAD framing. TLS does not require mTLS: evaluate a
pairing-pinned device TLS identity plus controller authorization inside TLS
before committing to client certificates and SecIdentity lifecycle management.
Secure Enclave protects a supported controller key; it does not by itself
authenticate a peer or require a certificate authority.

A native controller can anchor trust through explicit pairing without a public
domain or public CA. This is not the same as silently accepting self-signed
certificates, and it does not solve browser HTTPS trust. Keep full certificate
policy validation and an exact device trust binding. Do not ship a global
URLSession trust exception or import roots into the system trust store.

## Executed Transport Spike

`bash scripts/experiments/local-tls-probe.sh` builds the repository's pinned
Mbed TLS 3.6.6 upstream `ssl_server2` on macOS, generates disposable independent
P-256 keys/certificates, and tests Apple URLSession against a loopback-only
TLS 1.3 listener. Temporary certificates, private keys and the server are
removed on exit; nothing enters the package or production trust store.

Observed on 2026-09-10:

- HTTPS works with an explicit certificate pin and Apple trust evaluation.
- A different certificate pin and an absent pin both fail authentication.
- TLS 1.3 is required by both client and server and confirmed by the server.
- No client certificate, domain provisioning or system root installation is
  needed for this isolated native-client exchange.
- EC parameters must use the supported named-curve encoding. The initial
  explicit-parameter certificate was rejected by Mbed TLS, not worked around.
- Apple trust rejected the initial certificate without a suitable `serverAuth`
  EKU. The corrected certificate declares SAN, EKU, digitalSignature and
  non-CA basicConstraints; validation was never disabled.

This proves only host HTTPS interoperability and certificate-pinning rejection.
It does NOT prove an iOS daemon TLS listener, WSS, pairing, controller proofs,
Secure Enclave identities, revocation, downgrade resistance, browser UX, or
resource safety under hostile traffic. The probe pins the whole certificate;
production key continuity/renewal and DHCP-independent identity are still
decisions, not inferred from this test.

## Integration Boundary

The existing server is not a pluggable TLS HTTP stack. `HttpStreamServer.mm`
owns socket I/O and passes raw descriptors to `Term.mm`; terminal and signaling
then call `send`, `recv`, `shutdown`, and `close` directly. File and screen
streams also own long-lived writes. Wrapping only HTTP headers or the accept
loop leaves upgraded connections outside TLS or creates competing owners.

The next prototype must demonstrate one connection owner with bounded encrypted
read/write, cancellation and close semantics across HTTP, downloads, terminal
and signaling upgrades. Preserve partial I/O, deadlines and backpressure. Do
not run concurrent reads/writes on a TLS context without an explicit supported
serialization strategy. A loopback TLS proxy alone is insufficient: it does
not convey an authorized principal to the existing full-trust HTTP backend.

## Bootstrap And Authorization Invariants

1. Start protected setup through a genuinely local owner action or authenticated
   provisioning. An unauthenticated remote input event must not approve it.
2. Persist the protected policy and deny new untrusted access before creating
   any device key or displaying pairing material. Drain/terminate all existing
   capture, input, file and terminal paths. If quiescence cannot be verified,
   do not begin the ceremony. A crash must not reopen LAN access.
3. Owner-approved pairing material binds one device trust anchor, one ceremony,
   an expiry and explicit controller rights. Reject replacement of a live
   ceremony by unsolicited requests; enforce per-origin and global capacity.
4. Authenticate and authorize every externally reachable route and WebSocket
   before allocating privileged resources. Propagate that principal to each
   DataChannel. Loopback is not an administrator identity; preserve the explicit
   authenticated Relay path without implicitly granting its authority locally.
5. Replay protection cannot evict live entries. Capacity exhaustion rejects new
   work. Restarts, clock changes, retries and lost replies require defined
   replay/idempotence behavior. No command executes in TLS 0-RTT early data.
6. File APIs must not expose device/controller keys, grants or policy files.
   Root file write, shell and unrestricted automation are effectively device
   administration; do not pretend narrower media scopes constrain those grants.
7. Revocation invalidates live authority, not only the next login. Listener loss,
   lease expiry and failed handoff release capture, input and recordings.
8. Never migrate existing LAN users to paired-only access automatically. Test
   upgrades and explicitly block unsafe downgrades: old binaries do not know
   the new policy. Recovery must require an owner action and disclose that
   reopening untrusted LAN can expose keys. Existing compromise is out of scope.

## Bounded Next Spike

Budget: two focused engineering days, not an indefinite transport research
phase. Deliver one update to this ADR with test evidence and a go/no-go decision:

- iOS 14 rootful and iOS 15 rootless TLS server startup, entropy, restart and
  cleanup using the pinned dependency and actual packaged architecture.
- Native iOS HTTPS and WSS including mismatched identity, expiry, reconnect,
  cancellation, hostname/IP changes and certificate renewal.
- A proposed controller authentication choice with revocation and recovery;
  compare mTLS only against a concrete benefit/constraint, not as a TLS mandate.
- One refreshed route/principal matrix, protected-setup state machine and
  migration/browser impact assessment. Use synthetic keys and content.
- Memory/connection/time limits and a tested close-all path before a secret
  ceremony can start. Do not extract real keys through the current file API.

If a criterion fails, record the concrete blocker and the next bounded test.
Do not weaken the security invariants to meet the time budget. Another reviewer
must inspect the complete proposal and evidence before runtime local-auth APIs
are allocated. The implementation author may participate; model agreement alone
is not an independent security audit.

References: [TLS 1.3](https://www.rfc-editor.org/rfc/rfc8446.html),
[Apple server trust](https://developer.apple.com/documentation/security/certificate-key-and-trust-services/trust).
