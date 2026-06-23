# rctl Relay Admin UI

This is the relay admin SPA. It is separate from the device control client in
the repository root `web/`.

- Source: `relay/web-admin/`
- Build output: `relay/internal/relay/webdist/`
- Served by the Go relay under `/admin`
- Embedded into the Go binary with `go:embed`

The device control page served at `/control/devices/{id}` uses the root
`web/dist/index.html`, not this admin bundle.
