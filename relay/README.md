# Relay

The Go relay authenticates devices and administrators, brokers HTTP, stream,
terminal, and WebRTC traffic, persists enrollment state, and serves the separate
admin client from `internal/relay/webdist`.

- `cmd/`: runnable relay, setup, signing, and qualification tools.
- `internal/relay/`: network service and persistence.
- `internal/setup/`: transactional VPS lifecycle manager.
- `internal/deb/`: safe personalized-package generation.
- `web-admin/`: admin UI source.

Run `go test ./...`; also lint/build `web-admin/` after API or UI changes. Always
run `(cd web-admin && npm ci && npm run build)` before compiling a standalone
relay binary so its embedded admin client matches the current source. Docker,
Linux release builds, and the smoke script perform this step automatically.

For user installation and managed server updates, use the
[setup guide](../docs/SETUP.md), not a source build. See the
[relay protocol](../docs/RELAY.md), [security model](../docs/SECURITY.md), and
[version-scoped VPS qualification](../docs/SETUP-QUALIFICATION.md).
The [project status](../README.md#project-status) distinguishes source features,
qualification prereleases, and the published stable installer.
