# Public APT Repository

The public LAN-only package is available from the APT source:

```text
https://nobottomline.github.io/rctl-repo/
```

The feed is compatible with Cydia, Sileo, Zebra, and other package managers that
consume the standard flat Debian APT repository format. A custom domain is not
required; GitHub Pages provides the public HTTPS origin.

## Ownership boundary

The source monorepo is the only build and qualification authority. The separate
[`nobottomline/rctl-repo`](https://github.com/nobottomline/rctl-repo) repository
is a deliberately small distribution boundary: it stores the generator, static
depictions, and an append-only ledger of approved release tags. Generated APT
indexes and `.deb` files are assembled into the Pages artifact and are not
committed to either repository.

Only `rctl_<version>_iphoneos-arm.deb` from an immutable public GitHub Release is
accepted. The generator verifies the release and asset attestations, release
checksums, package identifier/version/architecture, required web client, and
absence of the relay plist or data resembling an enrollment credential. It then
generates `Packages` plus gzip, bzip2, xz, and zstd variants, creates `Release`,
and publishes both `InRelease` and `Release.gpg`.

The APT signing key is separate from the ECDSA device-update key. Its private
material exists only in the protected `apt-repository-signing` environment of
the distribution repository and in the maintainer's mode-0600 offline file. The
public key and fingerprint are published with the feed.

## Release synchronization

`release-publish.yml` publishes and anonymously verifies the immutable source
release first. It then uses a dedicated SSH deploy key, scoped for write access
to `nobottomline/rctl-repo` only, to append the tag to `releases.txt`. That push
starts the Pages workflow. The distribution workflow downloads the exact public
release assets rather than rebuilding them.

The source workflow reads the deploy key only from the protected
`apt-repository-publish` environment. The Pages workflow reads the repository
signing key only from `apt-repository-signing`. Neither secret is present in
source, artifacts, logs, or the generated site.

The initial feed contains immutable `v0.3.2`. Every later ledger entry must have
a schema-3 qualification report with `package_manager_upgrade` and
`package_manager_recovery` set to true. This prevents a normal APT in-place
upgrade from bypassing the clean transactional updater without physical-device
evidence that the package-manager path and recovery behavior are acceptable.

## Public and relay installations

The repository is intended for the ordinary LAN-only installation. A user who
starts with the self-hosted relay wizard does not need to add this source: the
wizard returns a private personalized package and relay admin owns its signed,
transactional updates.

A public installation can later be replaced by a personalized package with the
same package identifier. Relay identity lives outside the public package and
must survive any qualified package-manager update. Personalized packages,
enrollment tokens, device secrets, relay URLs, and VPS data must never be added
to the APT release ledger or Pages artifact.

## Maintainer recovery

The ledger operation is idempotent. If the source release is public but the APT
push or Pages deployment fails, rerun `release-publish.yml` or invoke
`scripts/publish_apt_release.sh vMAJOR.MINOR.PATCH` with the scoped deploy key.
The distribution workflow fails closed and keeps the prior successful Pages
deployment when release identity, qualification, signing, or package validation
does not pass.
