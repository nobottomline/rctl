# Development

Choose the component you are changing. A web or relay fix does not require a
device build, and a documentation edit does not require every test suite.
Contribution expectations live in [CONTRIBUTING.md](../CONTRIBUTING.md).

## First Checkout

Inspect `git status` before installing dependencies or building. Keep existing
work and local operator configuration intact.

| Work | Prerequisites and version source |
| --- | --- |
| Web and protocol | Node.js and npm; use the Node version in [CI](../.github/workflows/ci.yml) and each component's lockfile. |
| Relay and wizard | Go; [go.mod](../relay/go.mod) declares the minimum, CI and [Dockerfile](../relay/Dockerfile) pin build toolchains. |
| Device runtime | macOS, Xcode command-line tools, Python 3, `dpkg`/`dpkg-deb`, Theos configured through `THEOS`, and pinned [native dependencies](../third_party/webrtc/README.md). SDK/deployment targets live in [native-target.mk](../mk/native-target.mk). |
| Native iOS controller | Xcode and an available iOS simulator runtime; see [mobile/ios](../mobile/ios/README.md). This is not the jailbroken device runtime. |

Run `npm ci` in the affected web/protocol directory after checkout or a lockfile
change. Do not regenerate lockfiles merely to match a different local toolchain.
Build native dependencies with `make deps` before the first device package.
Package tooling and rootless prerequisites are described in
[ROOTLESS.md](ROOTLESS.md) and [PORTABILITY.md](PORTABILITY.md).

## Select the Checks

Commands below run from the repository root. Start with the specific test file
or package for the change, then run the relevant row before delivery.

| Change | Checks |
| --- | --- |
| Device control web | `(cd web && npm ci && node --experimental-strip-types --test tests/*.test.mjs && npm run build)` |
| Relay admin web | `(cd relay/web-admin && npm ci && npm run lint && npm run build)` |
| Relay or wizard | `(cd relay && go test ./... && go vet ./...)` |
| Shared wire contracts | `node protocol/generate.mjs --check` and `(cd protocol && npm ci && npm test)`; test affected receivers too. |
| Native device code | Focused `make test-*` target from the [Makefile](../Makefile), then `make test` for shared native behavior. |
| Package staging | `python3 scripts/test_stage_package.py`; audit the built artifact as described below. |
| Native iOS packages | `swift test --package-path mobile/ios/Modules/RctlRealtime` (or the affected sibling module). |
| iOS controller lifecycle/UI | `bash scripts/test-mobile-ios.sh`; creates and removes its own isolated simulator. |
| Relay integration | `./scripts/smoke_relay.sh`; inspect its prerequisites and use disposable state. |

After changing contract inputs, run `node protocol/generate.mjs` and commit the
generated sources with the contract change. Do not hand-edit generated output.
CI also runs vulnerability scans, workflow linting, cross-builds, and container
checks; see the [workflow](../.github/workflows/ci.yml) for the exact commands
and tool versions instead of maintaining another set of pins here.

## Build and Run

For browser development, run `(cd web && npm run dev)` or
`(cd relay/web-admin && npm run dev)` and use the address printed by Vite. A dev
page alone does not provide a device or relay backend. Use a configured test
backend or explicit test fixtures; do not present a mock session as device proof.
Track and stop only the processes started for your test.

The two web builds are different artifacts: `web/dist/index.html` is the device
control client; the admin client is embedded from `relay/internal/relay/webdist`.
Build the admin client before compiling a standalone Go relay binary. See the
[relay guide](../relay/README.md) for its build boundary.

For an incremental device development build, use `make package FINALPACKAGE=0`.
Package staging always rebuilds the device web client, including its product
and protocol version constants; an existing `web/dist/index.html` is not a
freshness guarantee. A failed web build stops packaging instead of shipping
the previous HTML. Native compilation remains incremental.
For audited LAN-only test artifacts, with `THEOS` configured, use:

```sh
scripts/build-packages.sh --scheme rootful
scripts/build-packages.sh --scheme rootless
```

The wrapper builds and audits the selected lane, prints the exact package path,
and does not install or publish it. Omit `--scheme` to build both lanes
sequentially. `scripts/release_check.sh <path-to-deb>` audits a specific artifact;
`make release-check` invokes the audit's default selection. Never confuse a
package-content audit with runtime qualification.

## Device and Release Safety

For an authorized rootful test device, use `scripts/deploy.sh` with an
operator-configured `RCTL_SSH` alias. Never use `make package install`. The deploy
script rejects rootless; use the installation and recovery procedure in
[ROOTLESS.md](ROOTLESS.md) instead. Keep physical or independently verified
recovery access before changing an injected process or package.

Use disposable relay state and simulator profiles. Do not point tests at a
production database or copy real credentials into test fixtures. The iOS test
script's optional `RCTL_LAN_TEST_ADDRESS` exercises a real device: set it only
for an explicitly authorized target, not as a shared default.

Media, input, reconnect, authorization, and recovery changes need the real
execution path tested. Record the tested version, platform, connection mode,
result, and remaining gaps without exposing personal identifiers or endpoints.

A build, commit, or passing CI is not permission to publish or deploy. Follow
[QUALIFICATION.md](QUALIFICATION.md) for release gates and
[ROOTLESS-RELEASE.md](ROOTLESS-RELEASE.md) for current rootless release evidence.
VPS lifecycle operations are documented in [SETUP.md](SETUP.md).
