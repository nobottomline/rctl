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
SHA256SUMS.sig
update-manifest.json
```

The relay container is published separately as:

```text
ghcr.io/nobottomline/rctl-relay:<version>
ghcr.io/nobottomline/rctl-relay@sha256:<digest>
```

Generated deployment files pin the immutable image digest. `latest` is never a
stored installation version. Release notes may show the human-readable tag.

The release also carries artifact attestations and SBOMs. The existing pinned
device-update ECDSA key remains independent from GitHub and container signing.
Its private half is never placed on a relay host. Releases are assembled as
drafts, fully verified, and only then published.

While the repository and container package are private, this pipeline is a
maintainer dry run and requires GitHub authentication. No private token may be
embedded in bootstrap output or generated VPS configuration. Anonymous install
is enabled only after both release assets and the GHCR package are public.

## Bootstrap contract

The convenience command downloads `install.sh` from a GitHub Release asset, not
from a mutable branch. The script has only four responsibilities:

1. Detect Linux CPU architecture.
2. Download the matching `rctl-setup` and `SHA256SUMS` into a private temporary
   directory.
3. Verify the binary checksum (and signature when the verifier is available).
4. Execute the verified binary with the original arguments.

All prompts, system mutation, rollback, and diagnostics belong to the Go
binary. A manual download-and-verify path is documented beside the one-liner.

## Wizard commands

```text
rctl-setup install       preflight, plan, confirm, apply, verify
rctl-setup preflight     read-only fresh-host and configuration checks
rctl-setup doctor        read-only deployment and public-path diagnostics
rctl-setup upgrade       backup, pull pinned release, apply, verify, rollback
rctl-setup backup        consistent database/config/TLS metadata archive
rctl-setup restore       validate archive, stop services, restore, verify
rctl-setup uninstall     explicit data-retention choice and owned-file removal
rctl-setup version       build and release metadata
```

Non-interactive automation uses a mode-0600 configuration file or environment
variables read by the process. Secrets are never accepted as command-line
flags, because arguments are visible in shell history and process listings.

Every mutating command has `--dry-run`. Re-running `install` reconciles an
existing installation when its ownership metadata is valid; it does not create
new secrets or replace state merely because a file already exists.

## Supported deployment profiles

### Dedicated host

The default profile owns ports 80/443 and deploys:

- the digest-pinned relay container;
- Caddy with persistent certificate state;
- coturn with a separately generated shared secret;
- a persistent relay SQLite volume;
- a root-owned mode-0600 environment file;
- restart policies and bounded container logs.

Only Caddy and the required TURN listeners are publicly reachable. Relay port
8080 stays on a private container network and is never published publicly.

### Existing reverse proxy

If 80/443 are already occupied, the wizard identifies the listener and stops
before mutation unless it is a supported Caddy/Nginx installation. It writes a
versioned candidate configuration, backs up the owned target, validates the
complete proxy configuration, applies atomically, reloads, and verifies. An
unknown proxy produces a ready-to-paste snippet and a resumable checkpoint.

The wizard does not kill unknown services or silently choose an alternate port.
A non-standard HTTPS port is an explicit advanced choice.

### Native systemd

The release Go binary and static web bundle can be installed without Docker.
This profile is for operators who deliberately select it. It has the same
filesystem, secret, backup, and health contracts as the container profile.

## Preflight and apply transaction

Preflight is read-only and reports every failed gate before making changes:

- supported Linux distribution, kernel, CPU and available disk/memory;
- effective root/sudo capability and a usable TTY when interactive;
- container runtime and Compose versions for the container profile;
- hostname syntax and final HTTPS origin;
- `A` and `AAAA` answers, including stale IPv6 records;
- whether the answers plausibly identify this host;
- ownership of 80/443 and required TURN ports;
- firewall state without modifying SSH access;
- clock synchronization, because TLS and signed metadata depend on time;
- conflicting prior rctl files, containers, volumes, or partial transactions.

An inside-the-VPS check cannot prove a cloud-provider security group is open.
That limitation must be explicit. ACME issuance plus a public-origin health
request provide the final reachability evidence.

Apply uses a transaction directory and an operation journal:

1. Acquire a global setup lock.
2. Generate secrets from the kernel CSPRNG and write them mode 0600.
3. Render all candidate files in the transaction directory.
4. Validate Compose and proxy configuration before installation.
5. Save hashes and backups for every pre-existing file that will be changed.
6. Install candidates atomically and start services.
7. Verify local health, trusted public TLS, admin login, WebSocket routing,
   database persistence across a restart, and TURN allocation.
8. Commit an ownership manifest only after verification succeeds.
9. On failure, restore prior files and services; preserve a redacted journal.

The ownership manifest records paths, modes, non-secret hashes, deployment
profile, release version/digest, service names, ports, and volume names. Upgrade
and uninstall refuse to remove unowned or unexpectedly modified paths without
an explicit operator decision.

## Filesystem and secret model

Default native host paths are:

```text
/etc/rctl/relay.env             root:root 0600
/etc/rctl/setup.json            root:root 0600 (no plaintext secrets)
/opt/rctl/compose.yaml          root:root 0644
/opt/rctl/Caddyfile             root:root 0644
/var/lib/rctl/                  root-owned persistent data root
/var/lib/rctl/relay/            SQLite data
/var/lib/rctl/caddy/            TLS state
/var/lib/rctl/coturn/           TURN state when needed
/var/backups/rctl/              root-only lifecycle backups
/var/log/rctl-setup/            redacted setup journals
```

The relay environment necessarily contains server-side secrets. It is never
included in ordinary diagnostics. `doctor --export` emits an allowlisted,
redacted bundle and reports file permission problems without printing values.
Admin/session/TURN secrets are independent and rotation is a lifecycle command,
not a reinstall side effect.

## Device package delivery

The final normal flow lives in the authenticated admin page:

1. Admin chooses **Add device**, supplies a display name, and confirms.
2. Relay obtains the current public package and signed release metadata.
3. An isolated packager helper validates package id, version, size, checksum,
   signature, and archive structure before creating an enrollment.
4. It injects only the relay URL, one-time enrollment token, and display name.
5. Relay streams the result to the authenticated session with
   `Cache-Control: no-store` and a generic attachment name.
6. Temporary input/output files are mode 0600, bounded, outside web roots, and
   deleted after download, expiry, cancellation, or process restart.
7. The enrollment remains short-lived and single-use. The device still appears
   pending and requires browser approval, retaining the existing security
   confirmation without any on-device UI.

Package generation is not performed inside an HTTP handler with an ad-hoc shell
command. The helper has a fixed executable path, a minimal environment, no
network access, bounded input/output, a timeout, and a narrow request schema.
The relay never accepts a caller-supplied package URL or filesystem path.

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

Backups are encrypted when exported off-host. A local backup may remain
root-only, but the command warns that it includes relay identity and session
state. Restore validates archive ownership, schema version, checksums, free
space, and target deployment identity before stopping services.

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
