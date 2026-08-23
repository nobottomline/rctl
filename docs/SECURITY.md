# Security Model

rctl has two deliberately different access paths. Internet control uses the
authenticated TLS relay. Local control uses an unauthenticated HTTP service on
the device and is only safe on a trusted LAN or through the USB tunnel.

## Local network policy

By default, `rctld` listens on `0.0.0.0:8080` for the local browser client and API. This interface
is intentionally unauthenticated in the current protocol. It exposes screen and
camera viewing, input injection, file operations, application actions, and a
root terminal. Anyone who can reach the port can control the device.

This is an explicit product constraint, not an accidental missing middleware:

- never port-forward `8080`, publish it through a reverse proxy, or expose it on
  guest, hotel, public, or otherwise untrusted Wi-Fi;
- use `iproxy 8080:8080` for a direct USB path, or a private network whose
  members are fully trusted;
- use the relay for internet access; installing relay configuration leaves the
  independent local path enabled unless an administrator explicitly changes it;
- enforce LAN isolation at the router/firewall when other clients are not
  trusted.

An approved device can be changed to `Relay only` in the relay admin page. This
binds port `8080` only to loopback, retaining the relay's on-device HTTP tunnel
while rejecting direct LAN connections. The transition requires a one-time
confirmation token and at least one enabled relay entry with a permanent
`DeviceSecret`; a one-time enrollment token is not sufficient.

If relay access is lost while Relay-only mode is active, recover over SSH and
restart the daemon:

```sh
/usr/local/bin/rctld --local-access lan
launchctl unload /Library/LaunchDaemons/com.greatlove.rctld.plist
launchctl load /Library/LaunchDaemons/com.greatlove.rctld.plist
```

The CLI changes only the policy value and preserves device and relay secrets.
It is an operator recovery path, not an iPad UI.

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
