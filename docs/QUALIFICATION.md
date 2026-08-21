# Release Qualification and Publication

This document defines the enforced transition from a release candidate to a
public immutable rctl release. It contains no production hostname, address,
credential, device identifier, or private test result.

## Security boundary

`release-draft.yml` and `release-publish.yml` must both be dispatched with
`--ref <tag>`. They reject a workflow ref or SHA that differs from the requested
`vMAJOR.MINOR.PATCH` tag. The tagged commit must be reachable from `main`, and
the package version in `control` must match the tag.

Draft creation builds and pushes only:

```text
ghcr.io/nobottomline/rctl-relay:candidate-<source-commit>
ghcr.io/nobottomline/rctl-relay@sha256:<candidate-digest>
```

It does not create the stable GHCR version tag. The setup binaries embed the
immutable candidate digest, so a qualified draft can be exercised without a
mutable image reference.

The publication report must come from the public candidate: anonymous image
pull and anonymous release bootstrap are part of the supported user journey.
An earlier private-repository rehearsal using a temporary read-only GHCR token
is useful engineering evidence but cannot satisfy `bootstrap` or replace the
final clean-VPS run.

Publication refuses to proceed unless all of these are true:

1. The repository is public and the release still exists as a draft.
2. The candidate image digest is anonymously readable before any registry
   credentials are configured in the publication job.
3. The exact tagged source commit has a successful `CI` workflow run.
4. The draft contains exactly the version-matched release set, `SHA256SUMS`,
   and one `rctl-qualification_<version>.json` report.
5. Reassembling the release set produces byte-identical checksums.
6. Every release artifact and the OCI image has repository-bound build
   provenance from the tag-bound draft workflow.
7. The OCI image exposes its BuildKit SBOM attestation.
8. The qualification report matches the tag, source commit, image digest,
   checksum-set digest, supported profile, freshness window, and report digest
   supplied by the operator.
9. Every required clean-VPS, TURN, device, lifecycle, and LAN check passed.

Only after those checks does publication promote the candidate digest to the
stable GHCR version tag. A pre-existing version tag is accepted only when it
already resolves to the exact qualified digest. Any mismatch aborts. The draft
is then published, allowing GitHub immutable releases to lock the tag and all
assets.

## Qualification report

The report is privacy-safe evidence binding the external acceptance run to the
exact artifacts under review. Schema 2 is strict: unknown fields, trailing
JSON, symlinks, oversized input, malformed identities, reports older than 30
days, reports over five minutes in the future, and any false or missing check
are rejected.

```json
{
  "schema": 2,
  "product": "rctl",
  "tag": "v1.2.3",
  "version": "1.2.3",
  "source_sha": "0123456789abcdef0123456789abcdef01234567",
  "relay_image": "ghcr.io/nobottomline/rctl-relay@sha256:...",
  "checksums_sha256": "...",
  "deployment_profile": "dedicated-domain",
  "completed_at": "2026-08-21T20:00:00Z",
  "checks": {
    "bootstrap": true,
    "bootstrap_idempotent": true,
    "acme": true,
    "acme_renewal": true,
    "https_wss": true,
    "turn_udp": true,
    "turn_tcp": true,
    "forced_turn": true,
    "package_personalization": true,
    "device_enrollment": true,
    "relay_control": true,
    "lan_control": true,
    "relay_restart": true,
    "doctor": true,
    "backup_restore": true,
    "relay_upgrade": true,
    "upgrade_rollback": true,
    "reset_admin": true,
    "interrupted_recovery": true,
    "device_update": true,
    "device_update_rollback": true,
    "uninstall_keep_data": true,
    "uninstall_delete_data": true
  }
}
```

The checks have the following minimum evidence contract:

- `bootstrap`: an anonymous clean-host install used the exact release assets
  and digest-pinned candidate image without pre-existing rctl or registry
  credentials; `bootstrap_idempotent`: repeating that bootstrap verified the
  owned deployment without rotating identity or secrets.
- `acme`: the public origin obtained a trusted certificate from the configured
  ACME issuer; `acme_renewal`: a forced renewal or staging-equivalent renewal
  completed and the renewed certificate was served afterward.
- `https_wss`: external HTTPS, authenticated admin session, protected device
  WebSocket routing, security headers, and relay restart persistence passed.
- `turn_udp` and `turn_tcp`: authenticated allocations and relayed traffic
  passed from an off-host client over each transport, including the configured
  relay port range; `forced_turn`: browser/device media and control passed with
  host and server-reflexive ICE candidates disabled or rejected.
- `package_personalization`: an authenticated admin request generated a
  no-store, version-matched package containing only the expected relay
  bootstrap plist, and unauthenticated generation was rejected;
  `device_enrollment`: that package completed one-time enrollment and explicit
  browser approval without on-device setup UI or reusable enrollment secrets.
- `relay_control`, `lan_control`, and `relay_restart`: real screen, input, and
  at least one non-screen control worked through the relay, independently over
  LAN with relay configuration installed, and again after relay restart.
- `doctor`: the installed deployment produced no failed checks after the other
  lifecycle tests.
- `backup_restore`: a changed persistent state was restored byte-for-byte from
  a verified backup; `relay_upgrade`: a newer valid relay release upgraded and
  retained identity, secrets, device state, and connectivity;
  `upgrade_rollback`: an applied target was made unhealthy and automatic
  rollback restored the previous release and cleared its checkpoint.
- `reset_admin`: admin/session secrets rotated, prior sessions stopped working,
  deployment identity and TURN secret remained stable, and the new login
  survived restart; `interrupted_recovery`: the lifecycle process was killed
  after target state was applied and `recover` restored a verified prior state.
- `device_update`: the external updater installed a newer signed/checksummed
  public package while preserving relay identity and both control paths;
  `device_update_rollback`: an injected post-install verification failure made
  the watchdog restore the prior working package and reconnect automatically.
- `uninstall_keep_data` and `uninstall_delete_data`: each explicit retention
  mode removed only owned resources, produced a valid recovery backup, and
  respectively preserved or removed the managed data directory.

The `relay_image` value is copied from the draft release notes.
`checksums_sha256` is the SHA-256 digest of the downloaded `SHA256SUMS` file,
not one of the entries inside it. The report itself must be named exactly
`rctl-qualification_<version>.json` and uploaded to the draft without replacing
another report:

```sh
gh release upload "$TAG" "rctl-qualification_${VERSION}.json"
report_sha256="$(sha256sum "rctl-qualification_${VERSION}.json" | awk '{print $1}')"
```

The report contains conclusions, not secrets or raw diagnostics. Keep detailed
command logs in the maintainer's access-controlled qualification record. Never
include a hostname, IP address, admin cookie, token, device identity, database
row, certificate private key, or package secret.

## Publishing

After reviewing the draft, report, and retained detailed evidence, dispatch the
publication workflow from the same tag:

```sh
gh workflow run release-publish.yml --ref "$TAG" \
  -f tag="$TAG" \
  -f image_digest="sha256:<qualified-digest>" \
  -f qualification_sha256="$report_sha256" \
  -f confirm="publish-$TAG"
```

After success, independently download the public assets and run
`gh release verify "$TAG"` plus `gh release verify-asset "$TAG" <path>` for
each file. Confirm that `ghcr.io/nobottomline/rctl-relay:<version>` and the
digest recorded in the immutable release notes resolve to the same OCI index.

Until this workflow succeeds and those post-publication checks are retained,
the candidate is not a supported public release.
