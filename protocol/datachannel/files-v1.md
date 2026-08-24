# Files DataChannel v1

Label: `files`. Transport: reliable, ordered SCTP DataChannel on the screen
PeerConnection. Text messages match `schemas/files-control.schema.json`; binary
messages are file chunks of at most `file_chunk_bytes` from `limits.json`.

Download state:

```text
idle -> send get -> receive get_meta -> receive binary* -> receive get_eof -> idle
                            \-> receive err -----------------------------> idle
```

Upload state:

```text
idle -> send put -> send binary* -> send put_eof -> receive put_ok -> idle
                    \-> send cancel / receive err -----------------> idle
```

Only one transfer exists per channel. Binary data outside the corresponding
active state is invalid. Declared and observed byte counts must agree before a
client exposes a completed result. Paths are additionally limited by UTF-8 byte
length even though JSON Schema string length counts Unicode code points.

Version 1 has no transfer id, offset, content hash, acknowledgement, atomic
upload destination, or resume. It is retained for bounded preview/share work.
Large downloads use the authenticated HTTP streaming path. A resumable protocol
must be a versioned successor; clients must not infer resume from this framing.
