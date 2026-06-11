# rctlaudioprobe

Diagnostic-only audio reverse-engineering target for `mediaserverd`.

It is intentionally not part of the top-level `SUBPROJECTS`, not staged into the
normal Debian package, and not loaded by `scripts/deploy.sh`.

Build only:

```sh
make -C audioprobe
```

Behavior contract:

- `%ctor` only.
- No hooks.
- No method replacement.
- No render-path modification.
- No network or IPC.
- Append-only log at `/tmp/rctl-audioprobe.log` when explicitly loaded into
  `mediaserverd`.

Manual loading is a separate, high-risk RE step and should only happen with no
active viewer connected.
