# Security Model

rctl has two deliberately different access paths. Internet control uses the
authenticated TLS relay. Local control uses an unauthenticated HTTP service on
the device and is only safe on a trusted LAN or through the USB tunnel.

## Trusted local control

`rctld` listens on `:8080` for the local browser client and API. This interface
is intentionally unauthenticated in the current protocol. It exposes screen and
camera viewing, input injection, file operations, application actions, and a
root terminal. Anyone who can reach the port can control the device.

This is an explicit product constraint, not an accidental missing middleware:

- never port-forward `8080`, publish it through a reverse proxy, or expose it on
  guest, hotel, public, or otherwise untrusted Wi-Fi;
- use `iproxy 8080:8080` for a direct USB path, or a private network whose
  members are fully trusted;
- use the relay for internet access; installing relay configuration does not
  disable or weaken the independent local path;
- enforce LAN isolation at the router/firewall when other clients are not
  trusted.

Adding local authentication later requires an explicit compatibility and UX
design. It must not silently break the one-file browser client or iOS 14 local
HTTP workflow. This release therefore documents and preserves the trusted-LAN
contract instead of changing it.

## Relay control

The public relay requires HTTPS/WSS, high-entropy device credentials, explicit
enrollment and approval, authenticated admin sessions, same-origin POST
actions, rate limits, and protocol-major negotiation. The managed profile keeps
the relay process on a private container network behind Caddy; only the TLS edge
and TURN ports are public.

Device secrets, enrollment tokens, admin/session secrets, signing keys, relay
configuration, databases, personalized packages, and qualification host data
must never enter source control, logs, release assets, or public documentation.

## Destructive actions and updates

Destructive device operations use POST plus short-lived confirmation tokens and
enforce protected paths/packages again on the device. Remote package updates
accept only a catalog signed by the P-256 key pinned in the installed package.
The external updater verifies both target and rollback packages before removal,
preserves relay identity, verifies runtime recovery, and rolls back on failure.

See [UPDATES.md](UPDATES.md), [RELAY.md](RELAY.md), and
[ARCHITECTURE.md](ARCHITECTURE.md) for the detailed protocols and trust
boundaries.
