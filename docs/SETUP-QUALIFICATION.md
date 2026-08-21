# Self-Hosted Setup Qualification

This record distinguishes implemented behavior from release qualification. It
contains no private hostname, address, credential, device identity, or package.

## 2026-08-21 engineering qualification

Source baseline: `main` through `7c11562`, plus the documentation record itself.
Release version remains `0.3.0`; no tag or public release was created.

### Passed locally

- Go release toolchain `1.26.6`: `go test ./...`, `go vet ./...`, setup race
  tests, Linux amd64/arm64 setup cross-build, and `govulncheck v1.7.0`.
  `govulncheck` reported zero reachable or imported vulnerabilities; one
  required-module advisory was not called by the program.
- Hermetic execution of the real `scripts/install.sh`: fresh install, owned
  upgrade, failed-upgrade binary preservation, dry-run non-activation, release
  checksum enforcement, and successful atomic binary activation. The private
  qualification path also passed from a local verified asset directory without
  network access and rejected a symlinked asset directory.
- Setup lifecycle failure tests: ownership conflict, backup tampering and size
  limits, restore rollback, upgrade rollback, keep/delete-data uninstall,
  uninstalled recovery, interrupted fresh install/backup/restore/upgrade, and
  SQLite session persistence checks. Upgrade rollback was also exercised after
  the target verifier performed a real SQLite schema migration and data write;
  the old schema and row were restored without the target column.
- Container readiness tests reject missing, duplicate, stopped, starting, and
  unhealthy required services. Relay and coturn healthchecks are mandatory;
  install and doctor no longer accept Docker's `running/unhealthy` state.
- A failed fresh install now preserves its redacted journal and can be retried
  successfully without manual cleanup. Symlinked journal paths and retained
  unowned backup state are rejected before mutation.
- Upgrade cancellation during target verification was exercised explicitly.
  Automatic rollback used a fresh bounded recovery context, restored the old
  deployment, and did not inherit the cancelled command context.
- Relay Go tests and race-sensitive setup tests; control client production
  build; relay admin lint and production build; production dependency audits
  for both web projects with zero reported vulnerabilities.
- Native host tests, iOS 14 arm64/arm64e debug package build, public-package
  secret audit, and rejection of a personalized package by the public release
  gate.
- Relay OCI image build and localhost runtime: capabilities, authenticated
  admin login, `package.personalization`, no-store response headers, generated
  Debian package validation, and public-release-gate rejection of that private
  package. An insecure `ws://` personalization attempt was rejected before the
  production-form `wss://` case passed.
- The final source baseline was rebuilt as a production relay image from the
  pinned base images and passed an isolated container smoke test reporting
  relay `0.3.0` and protocol `1.0` through `/v1/capabilities`.
- `actionlint v1.7.12`; pinned Caddy and coturn image indexes exist and include
  both `linux/amd64` and `linux/arm64` manifests.
- A complete local release set was assembled from the production `.deb` and
  four cross-compiled Linux binaries. Exact names, executable modes, Debian
  metadata, ELF architectures, setup version/source metadata, sorted SHA-256
  checksums, and checksum verification passed. Repository-level GitHub
  immutable releases were enabled and read back through the administration API.

### Externally blocked

GitHub Actions run `32510772362` for source `99e0113` created the relay,
container, control-client, and admin-client jobs, but GitHub started zero steps.
Every job has the same check annotation: recent account payments failed or the
Actions spending limit must be increased. This is an account-level runner
block, not a test failure. CI and the draft release/GHCR workflow must be
repeated after billing is repaired.

### Still required before a supported public release

1. Run the anonymous release bootstrap on a clean supported Debian/Ubuntu VPS
   with a new DNS hostname and no prior rctl state.
2. Qualify real ACME issuance/renewal, public HTTPS and WebSocket routing,
   cloud firewall rules, external UDP and TCP TURN allocation, and forced-TURN
   browser/device media.
3. Enroll an iOS 14 arm64e device from the admin-generated package and verify
   relay plus independent LAN control before and after relay restart.
4. Exercise backup, restore, upgrade, automatic rollback, interrupted-operation
   recovery, and both uninstall retention modes on that VPS.
5. Run the draft release workflow, inspect all checksums/provenance/SBOMs and
   multi-architecture GHCR pulls, then publish only after the recorded tag and
   package versions match.

Until these external gates pass, the wizard is implemented and locally
qualified but must not be described as fully production-qualified.
