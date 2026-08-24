# Wire Protocol Contracts

`protocol/` is the source of truth for contracts shared by the device runtime,
relay, browser, and native controllers. It contains data, schemas, fixtures, and
deterministic code generation; it is not a shared networking runtime.

`version.json` owns the protocol major/minor. Run:

```sh
node protocol/generate.mjs
node protocol/generate.mjs --check
cd protocol && npm ci && npm test
```

Generated files are committed so each owning toolchain can build independently.
CI rejects drift. A major mismatch is incompatible; a minor mismatch is a
feature-level warning and must remain usable through capability negotiation.

Fixtures contain no production hostnames, identifiers, credentials, or media.
`limits.json` records cross-implementation receive limits. JSON messages are
defined under `schemas/`; binary DataChannel framing and state machines are
defined in `datachannel/` and `signaling-v1.md`.

Within one protocol major, receivers ignore unknown object fields so a newer
minor can add metadata. Unknown message kinds and operations remain invalid and
must fail locally without invoking device behavior.
