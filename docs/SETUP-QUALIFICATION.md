# Self-Hosted Setup Qualification

This record distinguishes implemented behavior from release qualification. It
contains no private hostname, address, credential, device identity, or package.

## 2026-08-21 engineering qualification

Source baseline: `main` through `327182a`, plus the documentation record itself.
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
- Upgrade, restore, uninstall, and admin credential rotation now hold one
  lifecycle lock continuously across live verification, complete stack stop,
  the final stopped-state snapshot, apply, and commit or rollback. A test wrote
  new SQLite state immediately before stop and confirmed that exact state was
  present in the rollback archive. A separate test changed a managed file
  during stop; setup rejected it before snapshot, restarted the prior services,
  and cleared the temporary recovery checkpoint.
- Admin recovery rotates independent admin and session secrets while preserving
  TURN credentials, deployment identity, device state, and SQLite data. Tests
  cover dry-run, CSPRNG failure before maintenance, successful restart and
  persistence verification, failed-new-login rollback, interrupted-operation
  recovery, and blocking a second lifecycle operation.
- Container readiness tests reject missing, duplicate, stopped, starting, and
  unhealthy required services. Relay and coturn healthchecks are mandatory;
  install and doctor no longer accept Docker's `running/unhealthy` state.
- A failed fresh install now preserves its redacted journal and can be retried
  successfully without manual cleanup. Symlinked journal paths and retained
  unowned backup state are rejected before mutation.
- Upgrade cancellation during target verification was exercised explicitly.
  Automatic rollback used a fresh bounded recovery context, restored the old
  deployment, and did not inherit the cancelled command context.
- Cross-configuration restore rollback was exercised with a TURN-only target
  file. Failed target verification removed that file and restored the original
  non-TURN manifest. Restore now stops the complete stack before replacement so
  coturn cannot retain an old shared secret across a successful restore.
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
- Release publication is now separate from draft assembly. Draft builds use
  only a source-addressed candidate image tag. The publication workflow gates
  stable GHCR tag promotion and immutable release publication on successful CI
  for the exact tagged commit, exact remote assets and checksums,
  repository/workflow/ref/commit-bound provenance, a hosted runner, OCI SBOM,
  and a fresh-VPS qualification report bound to the same artifacts.
- Publication inspects the candidate digest before configuring registry
  credentials, so a private GHCR package cannot pass as the anonymous
  production bootstrap. A private rehearsal must use an isolated ephemeral
  Docker credential directory and is explicitly insufficient for publication.
- The strict qualification verifier and CLI passed positive identity binding,
  digest binding, unknown/trailing JSON, symlink, stale/future report, profile,
  and every incomplete-check rejection test. All Go tests, `go vet`, shell
  syntax validation, and `actionlint v1.7.12` passed after the workflow changes.

### Externally blocked

GitHub Actions run `32515961321` for source `9006b51` created the relay,
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
4. Exercise backup, restore, upgrade, admin credential reset, automatic
   rollback, interrupted-operation recovery, and both uninstall retention modes
   on that VPS.
5. Produce and upload the privacy-safe qualification report bound to the exact
   candidate image and `SHA256SUMS` digest.
6. Run the tag-bound draft and publication workflows, inspect all
   checksums/provenance/SBOMs and multi-architecture GHCR pulls, then perform
   independent immutable release and asset verification.

Until these external gates pass, the wizard is implemented and locally
qualified but must not be described as fully production-qualified.
