# Self-Hosted Setup Product

This document defines the supported zero-friction installation and lifecycle
contract for a self-hosted rctl relay. It is a product boundary, not merely a
convenience script. `docs/RELAY.md` remains the protocol and manual-operations
reference.

## Outcome

The normal user journey is:

1. Create a Linux VPS and point one domain or subdomain at it.
2. SSH to the VPS and run the release bootstrap.
3. Complete the interactive `rctl-setup install` checks.
4. Open the HTTPS admin page and download a personalized device package.
5. Install that package on the owned jailbroken iPad.
6. Approve the pending device in the browser and use it locally or through the
   relay. The iPad has no setup UI, PreferenceBundle, or secret-entry flow.

The installer must leave a system that can be diagnosed, upgraded, backed up,
restored, and removed without cloning this repository or installing a compiler.

## Product boundaries

- One relay origin serves admin, control, signaling, device WebSockets, update
  metadata, and any number of devices. Per-device subdomains are not used.
- A dedicated hostname such as `rctl.example.com` is recommended. A root domain
  is valid when it is otherwise unused.
- Trusted HTTPS/WSS is mandatory for the normal profile. Plain public HTTP and
  self-signed certificates are not production profiles.
- A bare public IP with a publicly trusted short-lived IP certificate is a
  separate profile. It must not be presented until automatic issuance and
  renewal have passed a real iOS 14/browser qualification run.
- The public `.deb` is LAN-only. Personalized packages and deployment secrets
  are never GitHub Release assets, container layers, logs, diagnostics, or
  committed files.
- Installing relay configuration never disables the independent LAN listener.

## Release contract

Every stable tag publishes immutable, version-matched artifacts:

```text
rctl_<version>_iphoneos-arm.deb
rctl-setup_<version>_linux_amd64
rctl-setup_<version>_linux_arm64
rctl-relay_<version>_linux_amd64
rctl-relay_<version>_linux_arm64
install.sh
SHA256SUMS
```

The relay container is published separately as:

```text
ghcr.io/nobottomline/rctl-relay:<version>
ghcr.io/nobottomline/rctl-relay@sha256:<digest>
```

Generated deployment files pin the immutable image digest. `latest` is never a
stored installation version. Release notes may show the human-readable tag.

Public releases also carry keyless GitHub/Sigstore artifact attestations and
the OCI image carries provenance plus an SBOM. The existing pinned
device-update ECDSA key remains independent from GitHub and container signing.
Its private half is never placed on a relay host. Releases are assembled as
drafts, fully verified, and only then published.

`update-manifest.json` is published only when a previous verified package is
available for rollback. It is signed by the independent device-update key and
is uploaded last; it is not a generic artifact produced for a first release.

While the repository and container package are private, this pipeline is a
maintainer dry run and requires GitHub authentication. No private token may be
embedded in bootstrap output or generated VPS configuration. Anonymous install
is enabled only after both release assets and the GHCR package are public.

## Bootstrap contract

The convenience command downloads `install.sh` from a GitHub Release asset, not
from a mutable branch. The script has only four responsibilities:

1. Detect Linux CPU architecture.
2. Download the matching `rctl-setup`, public LAN-only `.deb`, and
   `SHA256SUMS` into a private temporary directory.
3. Verify both artifacts against the release checksums and, when an
   authenticated GitHub CLI is present, their repository-bound build
   provenance attestations.
4. Execute the verified binary with the public package as an internal input and
   remove the temporary files when setup exits.

On a host with a valid ownership manifest, the same command selects
`rctl-setup upgrade`; otherwise it selects `install`. The verified target setup
binary remains an adjacent candidate while it performs the lifecycle command
and is atomically activated only after that command succeeds. A failed command
therefore leaves the previous lifecycle tool untouched. `--dry-run` removes the
candidate without changing the active binary. The target setup binary controls
the target deployment format without committing itself before relay rollback
is known to work.

All prompts, system mutation, rollback, and diagnostics belong to the Go
binary. A manual download-and-verify path is documented beside the one-liner.
The bootstrap fixes a trusted system `PATH`, uses a private `/tmp` directory,
accepts only `latest` or strict `vMAJOR.MINOR.PATCH` through `RCTL_VERSION`, and
installs only to `/usr/local/bin/rctl-setup` before executing it.

After the repository and GHCR package are public, the normal command is:

```sh
curl --proto '=https' --tlsv1.2 -fsSL \
  https://github.com/nobottomline/rctl/releases/latest/download/install.sh | \
  sudo sh
```

Pin a specific release by setting `RCTL_VERSION=vMAJOR.MINOR.PATCH` on the
`sudo` side. Do not pipe a mutable branch file to root. While the repository is
private, maintainers use `gh workflow run release-draft.yml`, inspect the draft
assets, and download them through authenticated `gh release download`; the
anonymous one-liner is intentionally unavailable.

## Wizard commands

```text
rctl-setup install       preflight, plan, confirm, apply, verify
rctl-setup preflight     read-only fresh-host and configuration checks
rctl-setup doctor        read-only deployment and public-path diagnostics
rctl-setup upgrade       backup, pull pinned release, apply, verify, rollback
rctl-setup backup        consistent database/config/TLS metadata archive
rctl-setup restore       validate archive, stop services, restore, verify
rctl-setup uninstall     explicit data-retention choice and owned-file removal
rctl-setup recover       repair an interrupted lifecycle transaction
rctl-setup version       build and release metadata
```

Non-interactive automation uses a mode-0600 configuration file or environment
variables read by the process. Secrets are never accepted as command-line
flags, because arguments are visible in shell history and process listings.

Every mutating command has `--dry-run`. Re-running `install` reconciles an
existing installation when its ownership metadata is valid; it does not create
new secrets or replace state merely because a file already exists.

`rctl-setup backup` is implemented as a short, explicit maintenance window. It
holds the global lifecycle lock, verifies current ownership/hashes, stops relay
and Caddy, snapshots all managed configuration plus `/var/lib/rctl`, preserves
Unix modes and ownership, and writes a sorted SHA-256 manifest under
`/var/backups/rctl`. Relay and Caddy are restarted and the public authenticated
path is verified before the candidate is atomically renamed as a successful
backup. A failed copy or verification removes the candidate and still restarts
the prior services. The backup directory is mode 0700 because it contains the
relay database, sessions, device identities, TLS state, and server secrets.

`rctl-setup restore --from /var/backups/rctl/backup-...` accepts only a direct
`backup-*` child of the managed backup directory. Before touching the running
installation it validates every declared path, mode, owner, size, and SHA-256
digest and checks that the archived ownership manifest agrees with the backup
metadata. Restore always creates and verifies a separate pre-restore backup,
then rechecks that the installed manifest and owned files did not change during
that maintenance window. It stops relay and Caddy, restores files through
bounded streaming copies and atomic renames, restarts all configured services,
and verifies the authenticated public HTTPS path. Failed apply, startup, or
public verification automatically restores and verifies the pre-restore state.
The command reports that rollback backup even when restore fails. Use
`--dry-run` to perform archive and ownership validation without stopping a
service or creating a new backup; unattended execution additionally requires
`--yes`.

`rctl-setup upgrade` is intentionally version-directed by the verified release
binary: its build metadata supplies the strictly newer `MAJOR.MINOR.PATCH`
version and digest-pinned relay, Caddy, and coturn images. It preserves the
installed origin, ACME and TURN settings, admin/session/TURN secrets, database,
sessions, device identities, and enrollment state. When device package
generation is enabled, the matching verified public `.deb` is mandatory and
its package version must exactly equal the target release. Before stopping the
current stack, setup creates a verified backup, validates candidate Compose and
Caddy files, and pulls target images. It then atomically replaces managed
files, verifies service health, trusted public routes, authenticated admin
access, and SQLite session persistence across a relay restart. Any failed apply
or verification restores the pre-upgrade backup and old pinned images. A
same-version rerun is an idempotent health check only when configuration and
every artifact hash still match that immutable release; conflicting artifacts
with the same version are rejected. Downgrades are rejected and intentional
rollback uses `restore`. `--dry-run` performs no image pull, backup, or service
operation.

`rctl-setup uninstall` requires exactly one explicit retention choice. Both
`--keep-data` and `--delete-data` first create and publicly verify a recovery
backup, stop and remove only the owned Compose project, and remove only paths
declared by the ownership manifest. It never prunes unrelated containers,
images, networks, or volumes. `--keep-data` preserves `/var/lib/rctl` after
removing its ownership manifest; `--delete-data` removes that live data root.
Both modes preserve `/var/backups/rctl`, setup journals, and the `rctl-setup`
binary. Unknown files in the managed configuration directories prevent those
directories from being removed but are never deleted. A failed filesystem
mutation automatically reapplies and verifies the pre-uninstall backup.

The retained setup binary can restore a selected managed backup even when the
installation manifest no longer exists. Recovery refuses pre-existing managed
configuration files, atomically reserves any retained data directory, applies
the verified snapshot, and starts and verifies the public deployment. On
failure it removes the partial deployment and puts the exact retained
uninstalled state back. On success the superseded retained data is removed.
The source backup is never consumed or modified.

Every lifecycle command writes a mode-0600 crash-recovery checkpoint outside
the data and backup trees immediately before its first service mutation. The
checkpoint contains an operation name and, where applicable, the already
verified rollback-backup path; it contains no secret values. A normal commit or
successful automatic rollback removes and fsyncs the checkpoint. While one is
present, install, backup, restore, upgrade, and uninstall refuse to start a
second transaction. `rctl-setup recover --dry-run` validates the checkpoint and
archive without mutation; `rctl-setup recover` restores the pre-operation
snapshot, removes only known obsolete rctl files, restarts the pinned stack,
checks public admin access and SQLite session persistence across a relay
restart, and then clears the checkpoint. Recovery from an interrupted backup
restarts and verifies the unchanged deployment and removes only hidden,
incomplete backup candidates.

## Supported deployment profiles

### Dedicated host

The default profile owns ports 80/443 and deploys:

- the digest-pinned relay container;
- Caddy with persistent certificate state;
- coturn with a separately generated shared secret;
- a persistent relay SQLite volume;
- a root-owned mode-0600 environment file;
- restart policies and bounded container logs.

The baseline TURN listener supports UDP and TCP on 3478 with short-lived HMAC
credentials. TURN-over-TLS is not silently claimed: it requires a certificate
handoff that is independently renewable and must pass forced-TCP/TLS browser and
iOS 14 qualification before the wizard advertises a `turns:` URL.

Only Caddy and the required TURN listeners are publicly reachable. Relay port
8080 stays on a private container network and is never published publicly.

### Existing reverse proxy

This profile is not implemented in the current release. The dedicated-host
preflight refuses occupied ports 80/443 before mutation. The intended future
contract is documented here so a later implementation cannot silently weaken
ownership or validation.

If 80/443 are already occupied, the wizard identifies the listener and stops
before mutation unless it is a supported Caddy/Nginx installation. It writes a
versioned candidate configuration, backs up the owned target, validates the
complete proxy configuration, applies atomically, reloads, and verifies. An
unknown proxy produces a ready-to-paste snippet and a resumable checkpoint.

The wizard does not kill unknown services or silently choose an alternate port.
A non-standard HTTPS port is an explicit advanced choice.

### Native systemd

This profile is not implemented in the current release. The relay is a normal
Go binary and can be operated manually under systemd, but `rctl-setup` currently
accepts only the dedicated container profile. A future native profile must keep
the same filesystem, secret, backup, and health contracts as the container
profile before it is advertised by the wizard.

## Preflight and apply transaction

Preflight is read-only and reports every failed gate before making changes:

- supported Linux distribution, CPU and available disk/memory;
- effective root/sudo capability and a usable TTY when interactive;
- container runtime and Compose versions for the container profile;
- hostname syntax and final HTTPS origin;
- `A` and `AAAA` answers, including stale IPv6 records;
- whether the answers plausibly identify this host;
- ownership of 80/443 and required TURN ports;
- local availability of required TCP/UDP listeners without modifying firewall
  or SSH policy;
- clock synchronization, because TLS and signed metadata depend on time;
- conflicting prior rctl files, Compose containers/networks, or partial
  transactions.

An inside-the-VPS check cannot prove a cloud-provider security group is open.
That limitation must be explicit. ACME issuance plus a public-origin health
request provide the final reachability evidence.

Fresh apply uses in-memory candidates, atomic file replacement, a redacted
operation journal, and the separate crash-recovery checkpoint:

1. Acquire a global setup lock.
2. Generate secrets from the kernel CSPRNG and write them mode 0600.
3. Render all candidates and structurally validate configuration and the public
   device package before creating deployment paths.
4. Reject every pre-existing unowned deployment path; fresh install never
   overwrites an existing file.
5. Install each candidate through fsync plus atomic rename, then validate
   Compose and Caddy before starting services.
6. Pull digest-pinned images and start the dedicated stack.
7. Verify local service health, trusted public TLS, admin login, WebSocket
   routing, database persistence across a restart, and local coturn health. A
   real external TURN allocation remains a clean-VPS/browser acceptance gate.
8. Commit an ownership manifest only after verification succeeds.
9. On failure, stop the partial stack, remove fresh owned paths, and preserve a
   redacted journal. Upgrade/reconfigure uses the verified backup transaction
   documented above rather than the fresh-install path.

The ownership manifest records paths, modes, secret classification, hashes,
deployment configuration, and release version. Immutable Compose content owns
the service, port, network, and bind-mount definition. Upgrade and uninstall
refuse to replace or remove unexpectedly modified owned paths.

## Filesystem and secret model

Default native host paths are:

```text
/etc/rctl/relay.env             root:root 0600
/opt/rctl/compose.json          root:root 0644
/opt/rctl/Caddyfile             root:root 0644
/opt/rctl/rctl-public.deb       root:root 0644 (verified LAN-only release)
/var/lib/rctl/                  root-owned persistent data root
/var/lib/rctl/relay/            SQLite data
/var/lib/rctl/caddy/            TLS state
/var/lib/rctl/setup/ownership.json  root:root 0600 ownership/config manifest
/var/backups/rctl/              root-only lifecycle backups
/var/log/rctl-setup/            redacted setup journals
/var/log/rctl-setup/recovery.json  root-only crash-recovery checkpoint
```

The relay environment necessarily contains server-side secrets. It is never
included in ordinary diagnostics. `doctor --export` emits an allowlisted,
redacted bundle and reports file permission problems without printing values.
Admin/session/TURN secrets are independent and rotation is a lifecycle command,
not a reinstall side effect.

## Device package delivery

The final normal flow lives in the authenticated admin page:

1. Admin chooses **Add device**, supplies a display name, and confirms.
2. The wizard-provisioned relay uses the version-matched public package that
   setup already verified and recorded in its ownership manifest.
3. The relay's bounded pure-Go package parser validates the Debian envelope,
   package id, version, architecture, compression, archive paths, size and the
   absence of an existing relay configuration before creating an enrollment.
4. It injects only the relay URL, one-time enrollment token, and display name.
5. Relay streams the result to the authenticated session with
   `Cache-Control: no-store` and a generic attachment name.
6. The base package is a read-only container mount loaded and validated once at
   relay startup. The personalized result exists only in bounded process memory
   for the duration of one serialized request; it is never written to a web
   root, database, container layer, backup, or persistent VPS path.
7. The enrollment remains short-lived and single-use. The device still appears
   pending and requires browser approval, retaining the existing security
   confirmation without any on-device UI.

Package generation never invokes a shell or `dpkg`, fetches from the network,
or accepts a caller-supplied package URL/filesystem path. The endpoint is an
authenticated, rate-limited POST with strict JSON, one active generation at a
time, `Cache-Control: no-store`, and rollback of the new enrollment if archive
generation fails before the response starts. Manual token creation remains an
advanced fallback when a deployment intentionally omits the public package.

## Upgrade and recovery

Relay upgrade is separate from the already implemented device updater:

- resolve a stable release to an immutable digest;
- verify release metadata before pulling or installing;
- take a consistent SQLite/config backup;
- keep the old digest and deployment files;
- apply and run compatibility/health checks;
- automatically restore the old digest and files on failure.

Persistent volumes and secrets are never replaced during a normal upgrade.
Database migrations must be forward-compatible with rollback or explicitly mark
a release as non-rollbackable before mutation.

Device updates continue to install the public LAN-only `.deb`; the detached
device updater preserves the personalized relay plist and `DeviceSecret`. A
personalized package is therefore needed once per device enrollment, not for
every release.

There is currently no off-host export command. Local backups remain root-only
and include relay identity, TLS state, and sessions; operators must encrypt the
entire backup before copying it off-host. Restore validates archive ownership,
schema version, modes, checksums, aggregate size, and target deployment identity
before stopping services.

## Failure and edge-case policy

- Interrupted install/upgrade is resumed or rolled back from the journal.
- Concurrent lifecycle commands are rejected by the global lock.
- DNS changes, ACME rate limits, closed cloud firewalls, broken IPv6, clock
  skew, disk exhaustion, read-only filesystems, and occupied ports have distinct
  actionable errors.
- A failed public-path check does not destroy a locally healthy prior install.
- Docker daemon loss, image-pull failure, Caddy renewal failure, coturn failure,
  corrupt SQLite, and incompatible protocol major are surfaced by `doctor`.
- No command performs `docker system prune`, deletes unrelated volumes, changes
  SSH policy, or rewrites an unknown firewall/proxy configuration.
- Diagnostics never include admin cookies, enrollment tokens, device secrets,
  relay environment values, package payloads, private keys, or database rows.
- Destructive uninstall requires an explicit choice between retaining and
  deleting data, prints every owned path, and takes a final backup by default.

## Acceptance gates

Before public release, all of the following must pass:

1. Unit tests for validation, rendering, ownership, redaction, locking, state
   transitions, rollback, archive handling, and malicious inputs.
2. Container integration tests for clean install, idempotent reinstall,
   interrupted apply, occupied ports, broken DNS/TLS, upgrade, rollback,
   backup/restore, and uninstall retention.
3. Package-generation tests for traversal, malformed archives, oversized input,
   concurrent requests, expiry, cancellation, restart cleanup, authentication,
   and absence of secrets in logs or public paths.
4. Browser verification of setup handoff, device-package download, approval,
   compatibility warnings, update state, and responsive error handling.
5. A private GitHub draft-release/GHCR dry run with checksum, signature,
   provenance, anonymous-pull expectations, and version consistency checks.
6. A clean temporary VPS test using a new hostname: one-line bootstrap through
   real ACME, iPad enrollment, LAN control, relay control, forced TURN, relay
   restart, device update, relay upgrade/rollback, backup/restore, and uninstall.

The public documentation may call the setup supported only after these gates are
recorded with exact versions and any untested limitations.
