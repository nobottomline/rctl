# Controller Revocation and Presence v1

These additive endpoints use the existing controller request proof: opaque
access bearer token plus fresh P-256 timestamp/nonce/signature headers. They
never accept an admin credential, controller ID, or secret in a query string.

## Transport and Identity Rationale

`me` denotes the controller authenticated by the request proof, not a user
account or the iPad being controlled. The handler derives its target from that
principal; the path spelling itself provides no authorization. Administrative
revocation of a chosen controller remains a separate admin-only endpoint.

Use HTTPS request/response for revocation and foreground heartbeats. Revocation
is a bounded state-changing command with an acknowledgement and does not require
an open streaming session. A heartbeat renews a server-timed lease; it must work
on the device list as well as during control. Existing signaling WebSockets and
WebRTC channels retain their realtime responsibilities.

A dedicated presence WebSocket would still need liveness timeouts, reconnects
and foreground lifecycle handling. An open socket or protocol-level pong does
not establish that a human is using the app. It is not justified just to replace
two small requests per minute per selected controller. HTTP connection reuse is
left to the networking stack; a heartbeat does not require a new TLS connection.
Reconsider a persistent event channel if bidirectional server events become a
product requirement, with measured latency/load goals and the same lease and
authorization boundaries. The current limits are safeguards, not load-test
evidence or a promise of unlimited capacity.

## Self-revocation

`POST /api/controller/me/revoke`, empty body, no additional scope required.
The target is exclusively the authenticated controller. In one transaction the
relay marks it revoked and invalidates all its access/refresh tokens, then
cancels its registered signaling sessions. Other controllers and device
enrollments remain unchanged. Success is `200 {"ok":true}`. The revoked record
remains in the admin list for visibility; it is not a device deletion.

The app deletes local credentials only after a valid success acknowledgement.
Network failure, unsupported endpoint, malformed acknowledgement and `401` do
not prove successful revocation. Keep the profile and explain that the operator
must retry or check relay admin. In particular, a lost success response followed
by `401` is ambiguous: the server may already have revoked the controller.
"Forget locally" is a separate, explicitly local operation, usable offline.
It must never claim to revoke server access.

## Foreground Presence

`POST /api/controller/presence`, empty body or `{"telemetry": {...}}`. Success:
`200 {"ok":true,"expires_in":90}`. Server time defines the lease; client time
does not control expiry. A successful heartbeat updates `controllers.heartbeat_at`
only while the controller is still active, including a recheck after auth.

Telemetry is optional condition data shown in relay admin: `battery_level`
(percent), `battery_state` (`unplugged|charging|full|unknown`), `low_power`
(bool), `thermal` (`nominal|fair|serious|critical|unknown`), `network`
(`wifi|cellular|wired|none|unknown`), `network_expensive` and
`network_constrained` (bool), `lan_ip` (private address literal),
`memory_available_bytes`. Battery percentage is an integer in 0...100; LAN IP
must be RFC1918 IPv4 or private IPv6, not a public/loopback address. It is not
evidence that two devices share a network. The relay validates
types and bounds, drops unknown keys, and rejects a malformed body with
`400 invalid_telemetry` without touching the lease. An empty heartbeat keeps the
last telemetry. The heartbeat also refreshes the controller's last IP and
User-Agent.

The static device profile travels separately through
`POST /api/controller/me/client` with `{"client": {...}}`, sent once after
pairing and when its fingerprint changes. Success includes
`{"ok":true,"accepted_schema_version":2}`. This version denotes the server's
accepted field contract, not the untrusted `client.schema_version`. Version 2
adds `protocol_minor` and optional `build_revision`, and retires disk capacity,
free disk space and boot uptime from automatic reporting. Those legacy keys
are ignored; other valid fields still work from older clients.

Both bodies have an 8192-byte total limit, including trailing whitespace, and
must contain exactly one JSON value. Only a matching accepted schema allows
the iOS client to cache its profile fingerprint. A legacy `{"ok":true}` remains
successful but unconfirmed: retry at most once per five foreground minutes
and on later launches until a compatible relay acknowledges the schema.
See `docs/CONTROLLER-AUTH.md` for the key whitelist.

The native client also reads `GET /api/controller/me` on device-list refresh,
before signaling, and after a successful presence heartbeat. Mutable name and
scopes update the saved profile without replacing relay identity, signing key,
or refresh token. A changed grant closes an already connected native session;
the user reconnects in View. This client-side behavior does not replace server
authorization or authorize editing scopes directly in the database.

## Mutable Permissions

The admin-only `POST /api/admin/controllers/{id}/permissions` accepts exactly
`{"scopes":["screen.view"],"expected_revision":1}`. Scopes use the pairing
allowlist and must be nonempty; no implied permissions are added. A scope alone
does not imply a usable media session: screen/camera entry points still require
their corresponding media permission, and reserved features remain unavailable.
Use the revoke endpoint to remove all access.

Success returns `{"ok":true,"scopes":["screen.view"],"authorization_revision":2,"changed":true}`.
Normalized no-ops return `changed:false` and the unchanged revision. Stale forms
return 409 `controller_permissions_changed`, revoked controllers return 409
`controller_revoked`, missing controllers return 404, malformed/unknown input
returns 400. The command uses existing admin session/CSRF/rate-limit policy; a
controller token cannot edit grants, including its own.

`authorization_revision` is a positive, monotonically increasing JSON-safe
integer, starting at 1 for migrated and new controllers. It appears in admin
lists, claim responses and `/me`. Every actual permission change and revocation
increments it. The app accepts missing revisions in old profiles, persists new
ones, and rejects subsequent regression. Identity and refresh credentials are
unchanged. A concurrent/uncertain save requires rereading rather than blindly
replaying a stale edit.

Grant mutations and session registration are serialized; authentication
snapshots are rechecked after registration. Existing controller signaling is
cancelled with WebSocket 1008, and device sessions close. An unresponsive link
is bounded by the device-issued authorization lease, not by the phone's UI or
presence heartbeat. See `signaling-v1.md` for the separate 20-second lease and
rolling-upgrade contract. Permission edits do not change presence status.

An active updated iOS session refreshes `/me` after policy closure and does not
auto-reconnect; ordinary network recovery obtains a fresh grant and starts in
View. An idle/foreground device list observes changes on its next refresh or
30-second heartbeat; an offline app observes them on reconnection. There is no
claim that an offline display changes immediately.

The controller sends a heartbeat every 30 seconds while the application is
active, for its selected relay only, including while viewing a remote session.
Leaving the foreground, forgetting a profile, switching relays or cancelling
the view task stops heartbeats. There is no background keepalive. Failed
requests do not extend the lease. No best-effort offline request is used: an
out-of-order goodbye must not erase a newer foreground heartbeat.

Ingress rate limiting is separate from pairing/refresh: 6000 requests/minute/IP,
then 6 authenticated heartbeats/minute/controller. The identity limit cannot be
selected by an untrusted request parameter. Heartbeats are not audit events.

`GET /api/admin/controllers` retains the existing `status: active|revoked` and
adds:

- `presence: online|offline|unknown`: online means a heartbeat less than 90
  seconds old, not proof of user interaction. Revoked always means offline.
  No heartbeat ever received means unknown, including legacy clients.
- `heartbeat_at`: optional last successful heartbeat, Unix seconds.
- `open_sessions`: current registered signaling session count, zero for revoked
  identities. It is not a count of distinct devices, proof of decoded video,
  or evidence of foreground presence.

`last_seen_at` remains the last authenticated API activity, throttled to one
write/minute. It must not be used as a substitute for foreground presence.
Heartbeat timestamps persist through relay restart and expire normally; open
session counts do not persist. Admin polling adds its refresh interval (currently
10 seconds) to the visible offline transition. Instant offline detection after
force-quit or network loss is not promised.

## Compatibility and Qualification

No protocol-major change is required. Old clients continue to pair and control;
their presence is unknown until they implement heartbeats. New admin clients
treat missing presence fields from old relays as unknown. New iOS clients stop
presence polling after `404`/`405` until the next foreground/profile lifecycle;
streaming and pairing continue to work. Self-revocation on an old relay fails
visibly and preserves the local profile.

Tests cover proof replay, per-controller limits, expiry boundaries, migration
repeatability, self-revocation token invalidation/session cancellation, other
controller isolation, the heartbeat/revoke race, acknowledgement failure and
foreground-task cancellation. Physical iOS background/force-quit and deployed
relay interoperability remain release qualification checks.
