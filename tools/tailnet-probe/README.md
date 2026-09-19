# Tailnet Probe

An isolated qualification tool, **not an rctl connection mode or release
artifact**. It does not proxy the device API, expose media, inject input, modify
VPN configuration, install a service, or change LAN/relay settings.

The module pins Tailscale separately from the relay/setup module. Pion TURN is
used only by the loopback integration test, not the diagnostic executable.
See [the integration contract](../../docs/TAILSCALE.md) for the intended product
flows and the unqualified boundaries.

## Local Checks

From this directory, using the Go version in `go.mod`:

```sh
go test -race ./...
go vet ./...
go run . --check
sh build-ios.sh /tmp/tailnet-probe
```

The iOS build requires macOS, Xcode's iPhoneOS SDK and `ldid`. It pins Go 1.26.6
because a future host toolchain can drop support for the iOS 15 target. It
creates an ad-hoc signed arm64 executable with an iOS 15.0 deployment target;
it neither transfers nor installs it. Jailbreak execution/trust requirements
remain separate from successful compilation. Do not deploy it over `rctld`.

`--check` prints non-sensitive runtime/build facts and exits without creating
state, registering a node or starting listeners. It is the first device test.

## Opt-In Network Probe

Only after the runtime check passes, prepare an isolated, owner-only directory
and a mode-0600 file containing a **one-off, non-ephemeral** Tailscale auth key.
Never put the key in arguments, shell history, source, test fixtures or a
public package. This probe does not validate the key's one-off policy; select
that policy when creating the key. Keep both files outside this checkout.

Set these non-secret path/identity variables for the test, then run:

```sh
./tailnet-probe \
  --state-dir "$PRIVATE_STATE_DIR" \
  --hostname "$NEUTRAL_HOSTNAME" \
  --allow-user-id "$CONTROLLER_TAILSCALE_USER_ID" \
  --auth-key-file "$PRIVATE_AUTH_KEY_FILE"
```

Enable MagicDNS and HTTPS certificates for the tailnet. Use a non-personal
hostname: certificate names are published in certificate-transparency logs.
The controller must join that tailnet and satisfy its grants/access rules.
Only an untagged peer owned by the explicitly allowed Tailscale user can call
`GET /healthz` over HTTPS. An identity lookup failure denies access; every
request is checked. All rctl routes return 404, not proxied responses.

Enrollment has a 90-second deadline. Ctrl-C/SIGTERM closes the HTTP listener
and tsnet instance. Auth URLs and upstream diagnostics are suppressed rather
than copied to logs; this is intentionally not a general troubleshooting CLI.
The diagnostic build requires the key-file argument on each start; persistent
node identity is stored separately by tsnet. Production one-time bootstrap
consumption and recovery are not implemented here.

After testing, stop the tracked process, remove its node from Tailscale, revoke
any unused enrollment key, and delete only the test's state/key directory.
Revoking an enrollment key alone does not revoke an already enrolled node.

## What Tests Establish

- No-network check does not initialize state.
- State/key permissions, owner and final-component symlink checks reject
  unsafe inputs; key reads are bounded and use the opened file descriptor.
- Identity input is explicit; diagnostics reject unauthenticated peers,
  unsupported methods, rctl routes and query strings.
- Pion TURN accepts separate packet connections, transfers a synthetic packet
  in both directions, rejects an incorrect password and denies a non-local
  peer address. All sockets are ephemeral loopback sockets and are closed.

The TURN test does **not** establish tsnet routing, browser ICE connectivity,
libjuice compatibility, production per-session port authorization, revocation,
allocation quotas, performance or energy use. There is no TURN listener in
the running probe. Use `go test -timeout 60s -race ./...` for bounded CI runs.
