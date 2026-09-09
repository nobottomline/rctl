# Pointer DataChannel v1

Optional device-created channels on a screen peer with `deviceControl`
permission: reliable ordered `pointer` for lease/button control, and unordered
`pointer-motion` with `maxRetransmits: 0` for relative deltas. Older peers may
omit either channel; clients must disable
mouse capture instead of synthesizing touch as a silent fallback. No change to
the existing `control` touch/key messages or native controller is required.

Requests are UTF-8 JSON, at most 1024 bytes, matching
[`pointer.schema.json`](../schemas/pointer.schema.json). `id` correlates each
reply; `owner` is a fresh random 128-bit token for each acquisition, not a device
identifier. It coordinates concurrent viewers, not authentication.

- `acquire`: create the virtual mouse only if unowned. The current owner may
  repeat acquisition, but this does not renew the lease.
- `state`: complete HID `buttons` mask plus relative `dx`, `dy` and vertical
  `wheel`. Bit 0 is left, bit 1 right, bit 2 middle, bits 3/4 auxiliary buttons.
  Each accepted state requires a strictly increasing `sequence`. Duplicate or
  stale states never reapply movement. Coordinates are mouse deltas, not screen
  coordinates; do not normalize or rotate them using framebuffer geometry.
- `release`: clear buttons and remove the service. Another owner cannot release
  the current owner. Releasing an absent service is harmless.
- `move`: `dx`, `dy`, `wheel` and a separate monotonic `sequence`, on
  `pointer-motion` only in the web client. No acknowledgement, retransmission or
  control request is sent on this lane. It uses the currently held buttons and
  cannot change them or renew the lease. Late/duplicate sequence values are
  ignored. A lost delta is not replayed; subsequent input remains independent.

Success: `{id, ok:true, pointer_version:1, active, lease_ms:1500, sequence}`.
Failure: `{id, error}`. Errors include `pointer_busy`, `pointer_not_owned`,
`stale_pointer_sequence`, `invalid_pointer_request`, `invalid_pointer_action`,
`invalid_pointer_state`, `hardware_pointer_unavailable`,
`pointer_dispatch_failed`, `pointer_overloaded`, `pointer_request_expired`, and
`pointer_device_timeout`. Malformed envelopes may return id 0; oversized,
binary or excessive per-peer messages are dropped, not acknowledged.
Replies may include `processing_ms`: daemon elapsed processing time, excluding
network transit and response transmission, for latency diagnosis.

Accepted states renew a 1500 ms monotonic lease; the SpringBoard main queue checks
it every 100 ms. A blocked main queue can delay cleanup; this is not a hard
realtime guarantee. Daemon IPC loss also clears the pointer. Only explicitly
acquiring a new lease can resume after expiry or reconnection.

The bridge allows three reliable requests in flight per peer (two states plus
cleanup) and one motion request; excess motion is dropped. The global daemon
limit is four. IPC waits run on a separate serial queue, not on
libdatachannel's callback threads. The daemon assigns one monotonic deadline
covering both its queue and SpringBoard dispatch: 100 ms for disposable motion,
400 ms for reliable control. Its IPC envelope prepends an 8-byte big-endian
deadline; browser JSON cannot override it. Expired commands are rejected before
HID execution, including after an IPC timeout. This does not measure transit
age inside SCTP or the network; long-latency relay gameplay remains unqualified.

The web client emits at most two reliable state requests in flight and preserves
button transitions in a 16-entry bounded queue. It independently aggregates
motion on a 16 ms timer, dropping deltas older than 150 ms or when the motion
channel has over 2048 buffered bytes. Deltas never enter the reliable queue.
Reliable request timeout
is 1400 ms; keepalive states are sent after 300 ms idle without waiting for the
previous acknowledgement when a slot is available. Correlated replies confirm
processing, not independently observed app behavior.
