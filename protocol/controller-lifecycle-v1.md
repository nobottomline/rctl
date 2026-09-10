# Controller Revocation and Presence v1

These additive endpoints use the existing controller request proof: opaque
access bearer token plus fresh P-256 timestamp/nonce/signature headers. They
never accept an admin credential, controller ID, or secret in a query string.

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

`POST /api/controller/presence`, empty body. Success:
`200 {"ok":true,"expires_in":90}`. Server time defines the lease; client time
does not control expiry. A successful heartbeat updates `controllers.heartbeat_at`
only while the controller is still active, including a recheck after auth.

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
