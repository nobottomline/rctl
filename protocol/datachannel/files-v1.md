# Files DataChannel v1

Label: `files`. Transport: reliable, ordered SCTP DataChannel on the screen
PeerConnection. Text messages match `schemas/files-control.schema.json`; binary
messages are file chunks of at most `file_chunk_bytes` from `limits.json`.

Download state:

```text
idle -> send get -> receive get_meta -> receive binary* -> receive get_eof -> idle
                            \-> receive err -----------------------------> idle
```

Upload state (transfer-id capable peers; see `files.transfer_ids` in the
device capability list — without it clients upload over HTTP and never place
a `put` on this channel):

```text
idle -> send put(id) -> receive put_started(id) -> send binary* -> send put_eof(id)
     -> receive put_ok(bytes,id) -> idle
        \-> send cancel(id) / receive err(msg,id) -> idle
```

A client streams binary chunks only after `put_started`; a `put` that is
refused or never accepted writes nothing. The daemon echoes the transfer id
in `put_started`, `put_ok`, and `err`; an acknowledgement answers exactly one
`put_eof` (byte counts must match the declared size, or the upload failed).

Only one transfer exists per channel. Binary data outside the corresponding
active state is invalid. Declared and observed byte counts must agree before a
client exposes a completed result. Paths are additionally limited by UTF-8 byte
length even though JSON Schema string length counts Unicode code points.

Upload-capable peers negotiate the `files.transfer_ids` device capability.
With it, every upload control message carries a transfer `id` that the daemon
echoes in `put_started`, `put_ok`, and `err`; a client streams binary chunks
only after `put_started`, and a `put` that is refused or never accepted writes
nothing. The acknowledgement answers exactly one `put_eof`, and its byte
count must equal the declared size or the upload failed.

Version 1 has no offset, content hash, atomic upload destination, or resume.
It is retained for bounded preview/share work. Large downloads use the
authenticated HTTP streaming path. A resumable protocol must be a versioned
successor; clients must not infer resume from this framing.
