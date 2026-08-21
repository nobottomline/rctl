# Self-Hosted Setup Qualification

This record distinguishes implemented behavior from release qualification. It
contains no private hostname, address, credential, device identity, or package.

## 2026-08-21 engineering qualification

Qualified release candidate: tag `v0.3.0` at `9b648fb`. This record may receive
post-qualification documentation commits after that immutable candidate. No
stable release was published.

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

### Passed on temporary VPS infrastructure

- A clean Ubuntu 24.04 amd64 VPS with approximately 2 GiB RAM passed aggregated
  host, DNS, port, Docker, Compose, storage, memory, clock, and ownership
  preflight checks. A second Ubuntu host with an unrelated service on port 443,
  no Docker, and DNS pointing elsewhere reported all conflicts without creating
  rctl files, networks, or containers.
- Fresh installation obtained a real Let's Encrypt certificate and exposed the
  relay only through Caddy. External HTTPS returned HTTP/2 200 with HSTS, CSP,
  no-sniff, and no direct relay port. Relay and coturn became healthy, and relay
  authentication state survived the install verifier's forced restart.
- Two failed install attempts exposed production-only defects before commit:
  the non-root coturn process could not read its mode-0600 configuration, and
  its file capability could not execute after dropping the entire capability
  bounding set. Install rolled back all managed state in both cases. Commit
  `8993f02` assigns the configuration to the pinned image's non-root UID/GID,
  reapplies ownership after upgrade/restore/recovery, and grants only
  `NET_BIND_SERVICE` after `cap_drop: ALL`.
- The route verifier originally rejected the relay's correct anonymous `401`
  response on the protected device WebSocket. Commit `8993f02` now accepts
  either a successful upgrade or explicit authentication rejection while still
  failing every other status or transport error.
- A verified backup, restore dry run, live restore, already-current upgrade,
  and post-restore doctor all passed. Doctor reported valid ownership and
  permissions, protected secrets, valid Compose, healthy services, local relay,
  and public HTTPS/WebSocket routes.
- An authenticated admin session generated an in-memory personalized package.
  Its Debian package id, version, and relay plist were verified, then the test
  enrollment, cookie, and downloaded package were deleted.
- The E2E wizard included `8993f02`, while the digest-pinned relay image and
  public package came from the immediately preceding `0.3.0` candidate. This is
  strong engineering evidence, but not the final exact-commit qualification
  required by the publication workflow.

### Hosted workflow status

The repository was temporarily made public for qualification because the
private-repository Actions allowance was exhausted. Exact-commit CI passed for
`9b648fb`: Go tests, vet, reachable-vulnerability scan, actionlint, both web
builds, multi-platform setup cross-build, container build, and container smoke
test all succeeded. The tag-bound draft workflow then built and attested the
multi-architecture OCI image, rebuilt the iOS package and four Linux binaries,
restored the expected executable modes, validated the complete release set, and
created an unpublished draft with seven expected assets. An independent local
download verified every `SHA256SUMS` entry, ELF architectures, the public
package release gate, and absence of qualification host data or relay secrets.
API readback confirmed the repository was returned to private immediately after
the workflow.

### Still required before a supported public release

1. Repeat anonymous release bootstrap using the final exact tagged release
   assets and anonymous GHCR image, then upload its bound qualification report.
2. Qualify ACME renewal, cloud firewall rules, external UDP and TCP TURN
   allocation, and forced-TURN browser/device media.
3. Enroll an iOS 14 arm64e device from the admin-generated package and verify
   relay plus independent LAN control before and after relay restart.
4. Exercise admin credential reset, failed-upgrade automatic rollback,
   interrupted-operation recovery, and both uninstall retention modes on a
   disposable VPS. Backup, restore, and already-current upgrade are already
   qualified on a real VPS.
5. Produce and upload the privacy-safe qualification report bound to the exact
   candidate image and `SHA256SUMS` digest.
6. Make the GHCR package anonymously readable, qualify an anonymous
   multi-architecture pull, produce the exact-artifact fresh-VPS report, then
   run the gated publication workflow and independently verify the immutable
   stable release.

Until these external gates pass, the wizard is implemented and locally
qualified but must not be described as fully production-qualified.
