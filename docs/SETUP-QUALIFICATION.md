# Self-Hosted Setup Qualification

This record distinguishes implemented behavior from release qualification. It
contains no private hostname, address, credential, device identity, or package.

## 2026-08-21 through 2026-08-22 engineering qualification

Qualification target: the immutable commit referenced by tag `v0.3.0`. Several
draft candidates were intentionally invalidated after real-host qualification
found defects; no stable release was published.

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
- Before the first public release, qualification found that the private half of
  the previously generated device-update key had not been durably retained. No
  public user package existed, so the pin was safely replaced once. The new
  P-256 private key is a mode-0600 maintainer file outside the repository; its
  derived public key matches the package pin and the production `.deb` passed
  the secret audit. A maintainer helper verifies curve, mode, and exact pin
  equality and rejects both loose permissions and a different private key.
- Setup now owns the optional signed device-update catalog URL. Strict config
  validation, CLI/config-file parsing, ownership serialization, relay
  environment rendering, and verified release-upgrade replacement passed Go
  tests. Operators no longer need to edit the managed secret environment file
  to enable the admin page's transactional update action.
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
- Admin and session secret rotation completed with its mandatory backup,
  restarted relay, verified the new login, and passed doctor without exposing
  the new secret. Uninstall with retained data preserved the data directory and
  restored successfully from its automatic backup. Uninstall with deleted data
  removed the managed data directory and left a backup that passed an
  uninstalled-state restore dry run.
- A qualification-only `0.3.1` upgrade used a pullable but invalid relay image,
  so candidate validation and backup completed and the target relay container
  was recreated before health verification failed. Automatic rollback restored
  the `0.3.0` manifest, healthy relay/Caddy/coturn stack, valid doctor result,
  and no pending recovery checkpoint.
- A separate upgrade was killed with `SIGKILL` after its checkpoint existed and
  target Compose state had been written. `recover --dry-run` identified the
  interrupted upgrade without mutation; `recover --yes` restored and verified
  `0.3.0`, then removed the checkpoint. Qualification deployments, generated
  packages, credentials, backups, logs, containers, and probe tools were
  removed from both temporary hosts afterward.
- A second off-host client completed a real UDP STUN request through the public
  coturn endpoint and received its expected reflexive address. This proves
  external UDP reachability to the STUN listener, but not authenticated TURN
  allocation, the relay port range, TCP allocation, or forced-TURN media.
- An authenticated admin session generated an in-memory personalized package.
  Its Debian package id, version, and relay plist were verified, then the test
  enrollment, cookie, and downloaded package were deleted.
- The E2E wizard included `8993f02`, while the digest-pinned relay image and
  public package came from the immediately preceding `0.3.0` candidate. This is
  strong engineering evidence, but not the final exact-commit qualification
  required by the publication workflow.
- A later exact-candidate run began from a host with no ownership manifest and
  no managed containers. The first preflight correctly rejected retained,
  unowned backup state without mutation. After the prior recovery data was
  preserved outside managed paths, the complete locally staged and verified
  draft set installed successfully with an anonymous pull of the digest-pinned
  image, real ACME, Caddy, relay, coturn, and device-package support.
- Repeating the identical bootstrap command selected the already-current path,
  left the environment and ownership manifests byte-identical, and verified the
  deployment. Supplying changed bootstrap identity data failed closed and left
  both files byte-identical. Doctor passed owned-file modes, secrets, Compose,
  service health, relay health, and trusted HTTPS/WebSocket routing.
- The real admin API rejected unauthenticated package generation, accepted an
  authenticated request, returned a version-matched package with `no-store,
  private`, and embedded a `Relays` entry and one-time `EnrollToken` without a
  `DeviceSecret`. The enrollment, session, and package were removed afterward.
- A live SQLite marker was created, captured by `backup`, deleted through the
  API, and restored by `restore`; API readback proved absence before restore and
  presence afterward. Admin reset made the old credential return `401`, allowed
  the new credential, and retained a verified pre-reset backup.
- A second off-host VPS completed authenticated relayed traffic through the
  public TURN endpoint over both UDP and TCP client transports. Each path sent
  and received five 100-byte messages through an external echo peer with zero
  loss. Only short-lived REST credentials crossed the SSH channel; the shared
  TURN secret never left the relay host and probe files were deleted.
- That external test exposed obsolete coturn 4.17 directives. The pinned image
  rejects `no-loopback-peers`, while CLI and DTLS are disabled by default and
  their negative options are deprecated. The generator now omits all three,
  retains explicit loopback/private `denied-peer-ip` ranges, and its rendered
  configuration started the pinned coturn image with no configuration warning.
- A later exact-source fresh-host run found that dedicated-host preflight
  checked TCP 443 but not the UDP 443 listener used by Caddy HTTP/3. The
  corrected wizard rejected independently occupied TCP and UDP 443 before
  creating managed state. After the unrelated listeners were stopped, the same
  verified asset set completed fresh install, real ACME, doctor, and an
  idempotent second bootstrap without changing secrets or ownership metadata.
- The real admin API rejected anonymous package generation and produced a
  version-matched, no-store personalized package for an authenticated session.
  A clean iOS install claimed its single-use enrollment, appeared pending,
  required explicit approval, and reconnected as an approved protocol-1
  device. Independent LAN control, relay HTTP control, toast, and the control
  page passed. Browser WebRTC rendered a live 834 by 1112 stream and one click
  emitted the expected pair of control DataChannel messages.
- Relay restart preserved the browser session, approved device identity, and
  live stream. Backup/restore recovered a deleted SQLite enrollment marker;
  admin reset invalidated the old password and sessions while preserving the
  device; keep-data and delete-data uninstall modes both removed the runtime
  and restored successfully from verified recovery backups.
- A qualification-only valid 0.3.1 target exercised a real newer-version relay
  upgrade while preserving SQLite state and the connected device. A deliberately
  mismatched 0.3.2 target then exposed that route verification accepted a
  healthy 0.3.1 runtime under a 0.3.2 ownership manifest. Setup now requires the
  runtime capability version to equal the managed release.
- The same mismatch exposed a second rollback defect when target and rollback
  used one image digest: state replacement could occur while the target still
  held SQLite/WAL handles, causing the persistence probe session to disappear
  after restart. All rollback paths now stop and remove the complete target
  stack before applying a snapshot. Real-host retest rejected the mismatch,
  completed automatic rollback, removed the recovery checkpoint, and passed
  doctor. The retained checkpoint from the first failed attempt also passed
  both `recover --dry-run` and `recover --yes`.

### Hosted workflow status

The repository was temporarily made public for qualification because the
private-repository Actions allowance was exhausted. The first exact-commit CI
and draft assembly at `9b648fb` passed, including all build, package, checksum,
provenance, and container smoke-test jobs. Independent verification of that
draft then found that qualification schema 1 could pass without
explicit evidence for certificate renewal, idempotent bootstrap, doctor,
authenticated package personalization, successful relay upgrade, or device
update and watchdog rollback. Commit `80021ff` replaces it with strict schema 2,
defines minimum evidence semantics for every check, and tests that every schema
field is represented in the mandatory failed-check set. The schema 1 draft was
deleted before publication.

Exact-commit CI then passed again for schema 2 candidate `c45b0c4`: Go tests,
vet, reachable-vulnerability scan, actionlint, both web builds, setup
cross-build, container build, and container smoke test all succeeded. Its
tag-bound workflow rebuilt and attested the multi-architecture OCI image, iOS
package, four Linux binaries, and complete seven-file draft release set. An
independent download verified every checksum, ELF architecture, public-package
gate, and absence of qualification host data or relay secrets.

Sigstore verification enforced the exact draft workflow, tag ref, source
commit, repository identity, GitHub-hosted runner, and SHA-256 subject for all
seven schema 2 draft assets. The new OCI index provenance bundle was retrieved
by digest from the GitHub Attestations API and passed the same policy against
GitHub's trusted root with an isolated empty Docker credential configuration.
API readback confirmed the repository was returned to private immediately after
the workflow.

The GHCR package was subsequently made intentionally public while the source
repository remained private. A later exact tagged candidate passed CI and draft
assembly again. With an empty Docker configuration, independent checks read the
OCI index and pulled both `linux/amd64` and `linux/arm64` manifests by digest.
The index contained two BuildKit attestation manifests; anonymous inspection
returned two SPDX 2.3 documents. GitHub/Sigstore verification bound the OCI
provenance and all seven draft assets to the exact tag, source commit, hosted
draft workflow, repository, and SHA-256 subjects. Every draft checksum and the
public package release gate passed.

Real-host testing then found and fixed idempotent bootstrap flag handling,
backup file-mode preservation under an operator `umask 077`, and the obsolete
coturn options described above. Local release review then found and fixed the
missing durable update-signing key and managed catalog wiring. Each discovery
invalidated the prior draft rather than weakening qualification. Only a later
tag rebuild from the corrected source is eligible; exact runtime checks must be
repeated before a report can be signed.

### Passed on a physical iOS 14 device

- The installed iOS 14 package exposed the transactional updater binary, pinned
  public key, protocol `1.0` capabilities, SpringBoard IPC, LAN HTTP service,
  and one authenticated relay connection at the same time. The updater state
  directory was root-owned and mode `0700`; no relay credential was read or
  copied during qualification.
- Two signed debug-package updates completed through the detached updater's real
  `dpkg -r` plus `dpkg -i` path. The latest transaction moved from package
  revision 315 to 316, reported `complete`, and left the daemon version,
  SpringBoard IPC, LAN service, and relay connection healthy. No updater or
  watchdog process remained after commit.
- A qualification-only package whose runtime deliberately failed verification
  exercised the external watchdog rollback. Device logs show the target package
  was installed, removed, and replaced by the verified previous package; the
  transaction recorded `rollback_complete`. A later successful update confirms
  the device remained recoverable and paired.
- These tests qualify the device transaction design and real iOS execution path.
  They used signed debug revisions, not the immutable public `v0.3.0` candidate,
  so they do not satisfy the publication report's exact-artifact device checks.

### Still required before a supported public release

1. Rebuild the tag after the final setup and update corrections and repeat anonymous
   amd64/arm64 image, provenance, checksum, SBOM, and clean-host bootstrap checks
   using that exact candidate.
2. Repeat forced-TURN browser/device media on the physical device. Real ACME,
   staging-equivalent renewal, cloud firewall reachability, and authenticated
   off-host UDP/TCP TURN traffic have passed engineering qualification.
3. Repeat enrollment, independent LAN and relay control, restart persistence,
   and device update/rollback on an iOS 14 arm64e device using the exact public
   candidate package and its publication catalog.
4. Complete and upload the privacy-safe report bound to the final image and
   `SHA256SUMS` without replacing any release asset.
5. Run the gated publication workflow and independently verify the immutable
   stable release, assets, checksums, provenance, SBOM, and public bootstrap.

Until these external gates pass, the wizard is implemented and locally
qualified but must not be described as fully production-qualified.
