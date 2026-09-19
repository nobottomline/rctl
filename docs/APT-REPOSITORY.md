# Public APT Repository

Add this source in Cydia, Sileo, Installer, Zebra or another compatible manager:

```text
https://nobottomline.github.io/rctl-repo/
```

The site provides add-source buttons. Refresh sources, search for **rctl**, and
install or update it. One source serves two separate packages with the same
identifier, `com.greatlove.rctl`:

| Layout | APT architecture | Tested platform |
| --- | --- | --- |
| Rootful | `iphoneos-arm` | iPadOS 14.4, unc0ver / Substitute |
| Rootless | `iphoneos-arm64` | iPadOS 15.5, Dopamine / ElleKit |

The package manager selects a compatible architecture; its name does not
determine the jailbreak layout. RootHide is not qualified. Both lanes use
ordinary release versions, without historical `~rootlessN` suffixes.

## Distribution Boundary

The source monorepo owns builds, runtime qualification and the stable release
decision. The separate [distribution repository](https://github.com/nobottomline/rctl-repo)
owns the static site, release ledgers, generator and signing workflow.
It downloads exact immutable release assets, without rebuilding or personalizing
them. GitHub Pages supplies HTTPS without requiring a custom domain.

Every admitted package must pass:

- Public, stable, immutable release identity and GitHub release-attestation checks.
- Asset verification against that attestation and an exact `SHA256SUMS` match.
- Package ID, version, architecture, dependencies and runtime layout checks.
- A non-empty web client and checks against symlinks, relay configuration
  and enrollment credentials.

The generator derives `Release` architectures from verified `Packages`.
It produces gzip, bzip2, xz and zstd indexes, web/native depictions,
`InRelease` and `Release.gpg`. The existing OpenPGP key is retained and its
fingerprint pinned. Private key material stays in the protected
`apt-repository-signing` environment and offline backup, never in source.

Before deployment, isolated Linux APT clients verify signatures, select and
download each architecture, and simulate installation and upgrade. The workflow
repeats these checks against the public feed. Simulations prove repository and
dependency resolution, not physical-device installation or recovery.

## Release Synchronization

After publishing and anonymously verifying a stable release,
`release-publish.yml` invokes `scripts/publish_apt_release.sh`. The publisher
clones the distribution repository and runs its public-artifact verifier for
both architectures before changing either ledger. It updates `releases.txt`
and `rootless-releases.txt` in one commit using the scoped APT deploy key.
The push starts the signed Pages build. Missing, private or invalid artifacts
abort publication; a failed build leaves the previous deployment available.

`apt-publish.yml` also handles stable releases published through GitHub or `gh`
and provides a manual retry action. The explicit call in `release-publish.yml`
is retained because releases created with `GITHUB_TOKEN` do not trigger another
workflow through the release event. Both routes use the same idempotent publisher.

The operation is idempotent, including recovery of a tag previously added only
to the rootful ledger. Tags must be increasing. Historical rootful-only releases
do not need rootless artifacts. To retry missed synchronization, run:

```sh
scripts/publish_apt_release.sh vMAJOR.MINOR.PATCH
```

This requires GitHub read access and write access to the distribution repository.
If both ledgers already contain the tag, rerun its Pages workflow instead. Do not
rerun source release-publication on an already public release.

### 0.4.4 Synchronization

The feed previously remained on rootful `0.3.2` after GitHub latest became
`0.4.4`. The old APT contract required additional runtime reports, including
a rootless report the source release workflow did not produce. Its publisher
also advanced only the rootful ledger.

APT now consumes the stable release decision and verifies the exact public
packages independently of those duplicate reports. This allows the existing
immutable `0.4.4` DEBs to be distributed without rebuilding, replacing release
assets or manufacturing test evidence. Source release qualification requirements
are unchanged; current evidence and remaining gaps are in
[ROOTLESS-RELEASE.md](ROOTLESS-RELEASE.md).

## Public and Relay Installations

Public packages contain no relay credentials and provide trusted-LAN access on
fresh installation. Existing identity, relay bindings and explicitly chosen LAN
policy live outside the package and must survive updates. A public package does
not add, remove or transfer a relay binding.

The relay wizard creates personalized packages privately. Those packages and
enrollment tokens must never enter APT. Relay's signed transactional updater
remains a separate route; do not run it concurrently with a package-manager
transaction.
