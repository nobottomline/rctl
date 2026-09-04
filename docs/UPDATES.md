# Transactional Device Updates

Device updates are initiated from the relay admin page. There is no app,
PreferenceBundle, prompt, or other UI on the iPad. The update path is disabled
when the relay is configured with `device_update_channel: off`. Official wizard
installations use a signed, version-bound stable catalog by default.

The public Cydia/Installer/Sileo/Zebra feed is a separate distribution channel.
Relay installations should continue to use this transactional updater. A
release is eligible for the public APT ledger only after its qualification
report proves the real package-manager upgrade and recovery paths; see
`APT-REPOSITORY.md`.

## Security model

- The package pins an ECDSA P-256 public key at
  `/usr/local/share/rctl/update-public-key.pem`. The corresponding private key
  must remain outside the repository and release artifacts.
- The catalog is a signed envelope. `payload` is base64 JSON and `signature` is
  an ASN.1 ECDSA signature over the decoded payload bytes using SHA-256.
- The signed payload contains the target version, protocol major, and an exact
  URL, SHA-256 digest, and byte size for every accepted `.deb`.
- Both target and rollback artifacts are downloaded and verified before package
  removal starts. The updater also checks each archive is
  `com.greatlove.rctl` and that its Debian version matches the catalog.
- Manifest and artifact URLs must be HTTPS and cannot contain URL credentials or
  fragments. A relay admin session cannot override the pinned update key.
- Key rotation requires a package signed by the existing key to install the new
  public key. Losing the private key intentionally disables remote updates for
  devices that pin it; do not add a network key-recovery path.

The release maintainer keeps the unencrypted PEM outside every repository, VPS,
container, CI artifact, and release asset. The default local convention is:

```sh
export RCTL_UPDATE_SIGNING_KEY="$HOME/.config/rctl/update-signing-key.pem"
test "$(stat -f %Lp "$RCTL_UPDATE_SIGNING_KEY" 2>/dev/null || stat -c %a "$RCTL_UPDATE_SIGNING_KEY")" = 600
```

Store a separate encrypted offline backup before the first public release. Once
any public package pins the matching key, never regenerate or silently replace
it: a deliberate rotation must be delivered as an update signed by the old key.
GitHub Actions receives only a base64 representation through the protected
`release-signing` Environment secret `RCTL_UPDATE_SIGNING_KEY_B64`. The workflow
decodes it to a mode-0600 file below `RUNNER_TEMP`, proves it matches the package
public pin, removes it before artifact upload, and never prints it. Configure a
required reviewer for this Environment so arbitrary branch jobs cannot obtain
the signing key.

Before building or signing a catalog, prove that the local private key is P-256,
mode `0600`, and matches the public pin shipped by the package:

```sh
make verify-update-key
```

## Release catalog

Build a catalog with the repository tool. It must include every installed
version that the release still supports, because each one is its own verified
rollback artifact, plus the target version. Per-version URLs keep historical
packages on their immutable release tags instead of duplicating them:

```sh
cd relay
go run ./cmd/rctl-update-manifest \
  -key "$RCTL_UPDATE_SIGNING_KEY" \
  -target 0.3.1 \
  -artifact-url 0.3.0=https://github.com/OWNER/rctl/releases/download/v0.3.0/rctl_0.3.0_iphoneos-arm.deb \
  -artifact-url 0.3.1=https://github.com/OWNER/rctl/releases/download/v0.3.1/rctl_0.3.1_iphoneos-arm.deb \
  -output rctl-update-stable.json \
  ../artifacts/rctl_0.3.0_iphoneos-arm.deb \
  ../artifacts/rctl_0.3.1_iphoneos-arm.deb
```

`-base-url` remains available for a custom server where all packages are in one
immutable HTTPS directory. It is mutually exclusive with `-artifact-url`.
Every URL is rejected unless it is plain HTTPS without credentials, query,
fragment, encoded path, or a filename mismatch.

Before publication, independently verify the envelope and every referenced
package. Offline qualification can point the verifier at a directory containing
the exact package filenames; publication downloads historical artifacts from
their signed URLs:

```sh
scripts/verify_update_catalog.sh \
  rctl-update-stable.json \
  artifacts/rctl_0.3.1_iphoneos-arm.deb
```

Upload the catalog and every referenced `.deb` without renaming the archives.
For a custom channel, configure the relay only after all URLs are live:

```text
RCTL_RELAY_UPDATE_MANIFEST_URL=https://releases.example.com/rctl/0.3.1/update-manifest.json
```

A separate release subdomain is optional. For small self-hosted deployments,
serve a dedicated path from the existing TLS relay domain and place this
location before the catch-all relay proxy:

```nginx
location ^~ /rctl-updates/ {
    alias /var/www/rctl-updates/;
    autoindex off;
    limit_except GET HEAD { deny all; }
    add_header Cache-Control "no-store" always;
}
```

Keep the directory and files root-owned and world-readable (`0755`/`0644`), and
publish the signed manifest last with an atomic rename. Never place the signing
private key in this directory or on the relay host.

An installed version absent from the signed catalog is not updateable. This is
intentional: proceeding without a verified rollback package is forbidden.
The official release workflow accepts a comma-separated `rollback_tags` input so
devices may safely skip releases. The managed stable URL is bound to the same
version as the relay rather than mutable `latest`; upgrading the relay advances
it transactionally. The admin action is hidden, and the endpoint rejects the
request, when a device already reports the catalog target version.

The draft workflow requires `release-signing` and includes the signed catalog in
`SHA256SUMS` and repository-bound build provenance. The publish workflow verifies
the signature against the package pin, strict payload schema, every artifact's
package identity/version/architecture/size/SHA-256, and the exact release set
before making the release immutable.

## Runtime transaction

1. Relay admin calls `POST /api/admin/devices/{id}/update`.
2. The relay obtains a device confirmation token bound to the configured
   manifest URL, then calls `POST /v1/update` through the authenticated tunnel.
3. `rctld` writes a mode `0600` request and starts the signed
   `/usr/local/libexec/rctl-updater` as a separate process, which immediately
   creates an independent session and closes inherited descriptors before
   returning `202 Accepted`. Before spawning, the daemon atomically publishes a
   non-terminal `queued` status with the new job ID, so polling can never mistake
   a terminal result from an earlier transaction for the accepted job. No update
   work runs in the replaceable daemon; the already mapped executable remains
   valid when its package pathname is removed.
4. The updater locks the global update state, verifies the signed catalog, and
   downloads and verifies target and rollback packages.
5. It backs up the relay plist, including every `DeviceSecret`, and starts a
   second detached copy as the watchdog.
6. It performs `dpkg -r com.greatlove.rctl` followed by `dpkg -i target.deb`.
   Upgrade-in-place is deliberately not used because loaded jailbreak dylibs can
   retain stale code-signing state.
7. It restores the relay plist and verifies all of the following before commit:
   exact Debian package version from dpkg, live daemon semantic version and
   protocol via `/v1/capabilities`, SpringBoard IPC via `/v1/deviceinfo`, and at
   least one relay connection via `/v1/relay_status` when a paired relay was
   present before the update.
8. Any install error, failed verification, parent exit, stale heartbeat, or
   watchdog deadline triggers the same clean remove/install flow with the
   verified previous package.

State is exposed through `GET /v1/update_status` and shown in device details in
the relay admin page. Logs and rollback material live below
`/var/mobile/Library/Caches/com.greatlove.rctl/update`, which the file API treats
as protected runtime state. Verified success and rollback remove downloaded
packages, partial downloads, and the relay identity backup while retaining small
logs and status markers. A failed rollback deliberately retains recovery
material for SSH-assisted repair.

## Rollout and recovery

Deploy in this order: relay release first, then update devices from its signed
catalog. Protocol minor and component version differences warn but
remain connected. A protocol major mismatch is the only compatibility condition
that rejects a device connection.

The updater and watchdog are package-external processes only during a
transaction. If automatic rollback also fails, do not repeatedly issue updates;
recover over SSH with `scripts/deploy.sh` and retain the update log for diagnosis.
