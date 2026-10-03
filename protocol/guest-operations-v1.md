# Guest Operations v1

Requires device feature `guest.operations_v1` and the protected `guest-v1`
signaling envelope. This complements `guest.scoped_sessions_v1`; it does not
reinterpret native controller scopes. `permissions` uses the generated
[guest registry](guest-permissions.json). The authorization revision, internal
session owner and sleep-inclusive deadline come only from the bridge.

The reliable `guest-operations` DataChannel carries UTF-8 JSON requests:

```json
{"id":1,"op":"files.list","args":{"path":""}}
```

Responses correlate the positive, JavaScript-safe integer ID:

```json
{"id":1,"result":{"items":[]}}
```

A failure uses `{"id":1,"error":"permission_denied"}`. Messages are limited to
49,152 request bytes and 65,536 reply bytes. At most two native requests are in
flight, with 100 accepted requests per second and a bounded browser queue.
No browser-controlled owner, revision, rights, deadline or device ID is accepted.
Unknown operations fail closed. Each operation checks its exact permission.

Native operation groups are device info/diagnostics/brightness/orientation,
clipboard read/write, apps list/launch/open_url, input text/pointer, screen
snapshot, audio playback/microphone/record/output, Talk route, camera
live/snapshot/record, capture download, media browse/preview/original/delete,
exchange files, selected system operations and terminal open/read/write/resize/
close. Operation names and exact rights are defined in `GuestDispatcher.mm`;
[detailed semantics](../docs/GUEST-ACCESS.md) describe the resource boundary.
Talk speaker/mic/both requires each selected destination's permission.
`capture.status` returns only the session's owned microphone/camera recording
flags, filtered to its recording permissions. The client polls while recording
to reflect native duration, size and disk-space stops.

An open/preview/export returns `{transfer,size,name}` with an opaque session-owned
handle. `transfer.read` takes `{transfer,offset}` and returns a base64 chunk,
echoed offset and EOF; chunks are at most 24,576 bytes. `transfer.close` releases
the descriptor. The creating operation's permission remains attached to the
handle. A handle in a different session is not found. File paths are relative
to the private exchange root, never device absolute paths.

Upload begin takes `{path,size,overwrite}`; chunks take exact `{offset,data}`;
commit accepts only the declared exact size. Cancel/end deletes the private
temporary file. Upload without overwrite uses atomic no-replace completion.
Overwrite requires both `files.upload` and `files.overwrite`. Limits, descriptor
walking and artifact admission remain device-side decisions.

Destructive operations require `confirmation.issue` with `{operation,args}`,
then the exact operation/args plus its returned `token`. Tokens expire after
30 seconds, are single-use and belong to the session. Issuance and consumption
both require the action's permission. Confirmation cannot widen access.

Terminal data uses bounded base64. Dimensions are columns 20–500 and rows 5–200.
Writes report accepted bytes; partial writes are explicit failures in the UI.
Root terminal is full device authority, not a restricted command sandbox.

Revocation/revision changes retire the bridge lease before native drain. Replies
from retired work are dropped. Owned work/resources must drain before a `closed`
ACK. A failed cleanup remains pending and cannot be reported as confirmed.
