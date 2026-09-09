# Local Discovery v1

Status: additive discovery contract. This does not change the control protocol
version, authenticate a device, or enable any device action.

## Advertisement

Register `_rctl._tcp` in `local.` only after the LAN HTTP listener and handlers
are ready. SRV carries the actual listener port. Default instance name is
`rctl`; the system responder resolves collisions. Names are at most 63 UTF-8
bytes. Deregister when LAN is disabled; responder failure is recoverable and
must not affect HTTP, Relay, or manual address entry. Retry registration with
bounded exponential backoff, 1 to 60 seconds, with one registration at a time.

TXT uses DNS length-prefixed entries (one octet followed by that many bytes):

| Key | Value |
| --- | --- |
| `txtvers` | Exactly `1` |
| `pv` | Control protocol `major.minor`, canonical decimal components 0..65535; major >= 1 |

Reject missing keys, duplicate keys (ASCII case-insensitive), invalid key bytes,
truncated entries, empty entries, malformed versions, or an encoded record over
400 bytes. Keys are printable ASCII excluding `=`; unknown keys are ignored
after structural validation. Known values are case-sensitive ASCII. Do not
publish names, model, IDs, fingerprints, relay metadata, or secrets in TXT.
SRV can still expose the system hostname; this is not network anonymity.

`fixtures/discovery-v1.json` contains synthetic byte-exact test cases. Records
with a different protocol major are structurally valid but not connectable.

## Resolution And Lifecycle

Service identity is the exact instance name plus normalized type and domain,
not a persistent device ID. Group interfaces under that identity; never merge
distinct service instances by display name. Accept only this service type in
`local.`. Keep at most 64 services, 8 interfaces/addresses per service, and four
active resolutions. A resolution has one five-second deadline including SRV
and address lookup. Ignore callbacks from replaced or cancelled attempts.

Use DNSServiceResolve then DNSServiceGetAddrInfo with interface provenance.
Validate the returned TXT again (not a cached NWBrowser dictionary). Reject
non-local SRV hostnames before address lookup. Request IPv4 only: the current
daemon listener is AF_INET. Select only RFC1918 literals and ports 1..65535;
reject public, loopback, link-local, multicast and unspecified addresses before
any application TCP request. Pin the selected literal in LocalDeviceAddress;
do not subsequently connect using the service hostname. DNS-only resolution
does not probe capabilities, signal WebRTC, or start capture. Resolved hints
are re-resolved on explicit selection before capabilities preflight.

Browse only after opt-in and while Devices is visible and active. Cancel on
background/dismissal; retain no trusted association across browse generations.
Responder failure/permission denial keeps manual entry available, not exempt
from local-network permission or network isolation. A browser result is
`Discovered`, never `Paired` or `Reachable` without the corresponding proof.

Save by exact endpoint only after explicit user action and capability preflight.
Changing an existing saved address requires explicit selection and confirmation;
never infer that two addresses are the same device from unsigned metadata.
Saved profile UUIDs and custom names remain unchanged on confirmed replacement.
Discovery and saved-device probes share a foreground-only budget: do not run
background capability sweeps while resolving discovery results.
