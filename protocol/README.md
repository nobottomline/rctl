# Wire Protocol Contracts

`protocol/` is the source of truth for contracts shared by the device runtime,
relay, browser, and native controllers. It contains data, schemas, fixtures, and
deterministic code generation; it is not a shared networking runtime.

`version.json` owns the protocol major/minor. Run:

```sh
node protocol/generate.mjs
node protocol/generate.mjs --check
```

Generated files are committed so each owning toolchain can build independently.
CI rejects drift. A major mismatch is incompatible; a minor mismatch is a
feature-level warning and must remain usable through capability negotiation.

Fixtures contain no production hostnames, identifiers, credentials, or media.
