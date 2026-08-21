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

Publication refuses to proceed unless all of these are true:

1. The repository is public and the release still exists as a draft.
2. The exact tagged source commit has a successful `CI` workflow run.
3. The draft contains exactly the version-matched release set, `SHA256SUMS`,
   and one `rctl-qualification_<version>.json` report.
4. Reassembling the release set produces byte-identical checksums.
5. Every release artifact and the OCI image has repository-bound build
   provenance from the tag-bound draft workflow.
6. The OCI image exposes its BuildKit SBOM attestation.
7. The qualification report matches the tag, source commit, image digest,
   checksum-set digest, supported profile, freshness window, and report digest
   supplied by the operator.
8. Every required clean-VPS, TURN, device, lifecycle, and LAN check passed.

Only after those checks does publication promote the candidate digest to the
stable GHCR version tag. A pre-existing version tag is accepted only when it
already resolves to the exact qualified digest. Any mismatch aborts. The draft
is then published, allowing GitHub immutable releases to lock the tag and all
assets.

## Qualification report

The report is privacy-safe evidence binding the external acceptance run to the
exact artifacts under review. Schema 1 is strict: unknown fields, trailing
JSON, symlinks, oversized input, malformed identities, reports older than 30
days, reports over five minutes in the future, and any false or missing check
are rejected.

```json
{
  "schema": 1,
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
    "acme": true,
    "https_wss": true,
    "turn_udp": true,
    "turn_tcp": true,
    "forced_turn": true,
    "device_enrollment": true,
    "relay_control": true,
    "lan_control": true,
    "relay_restart": true,
    "backup_restore": true,
    "upgrade_rollback": true,
    "reset_admin": true,
    "interrupted_recovery": true,
    "uninstall_keep_data": true,
    "uninstall_delete_data": true
  }
}
```

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
