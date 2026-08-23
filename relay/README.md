# Relay

The Go relay authenticates devices and administrators, brokers HTTP, stream,
terminal, and WebRTC traffic, persists enrollment state, and serves the separate
admin client from `internal/relay/webdist`.

- `cmd/`: runnable relay, setup, signing, and qualification tools.
- `internal/relay/`: network service and persistence.
- `internal/setup/`: transactional VPS lifecycle manager.
- `internal/deb/`: safe personalized-package generation.
- `web-admin/`: admin UI source.

Run `go test ./...`; also lint/build `web-admin/` after API or UI changes. See
`docs/RELAY.md`, `docs/SETUP.md`, and `docs/SECURITY.md`.
