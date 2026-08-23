# Shared Native Core

Code here is shared by the native runtime components. Keep process-specific
hooks in `springboard/`, `daemon/`, `app/`, or `audio/`.

- `audio/`: Opus and virtual-microphone DSP helpers.
- `capture/` and `encode/`: capture/encoding primitives.
- `input/` and `ipc/`: validated input and process IPC contracts.
- `net/` and `stream/`: HTTP, relay, media-library, and stream transports.
- `privacy/` and `security/`: privacy state and destructive-action policy.
- `protocol/` and `update/`: compatibility and update request contracts.

Public headers in these directories are compatibility boundaries. Validate all
untrusted lengths, paths, identities, and state transitions at entry points.
