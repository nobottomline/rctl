# Public APT Repository

The public LAN-only package is available from the APT source:

```text
https://nobottomline.github.io/rctl-repo/
```

The feed is compatible with Cydia, Installer, Sileo, Zebra, and other package
managers that consume the standard flat Debian APT repository format. A custom
domain is not required; GitHub Pages provides the public HTTPS origin.

The published feed currently advertises only `iphoneos-arm` (rootful). Sileo on
Dopamine/rootless expects `iphoneos-arm64` and can reject this feed with
`Didn't find architectures` followed by `Could not find release file`, even
when the server returns the Release file successfully. Package-manager format
compatibility is not a claim of rootless runtime support. Use the separate
[manual rootless test build](ROOTLESS.md) until that lane is qualified; do not
add an unsupported architecture to Release just to suppress Sileo's check.

## Ownership boundary

The source monorepo is the only build and qualification authority. The separate
[`nobottomline/rctl-repo`](https://github.com/nobottomline/rctl-repo) repository
is a deliberately small distribution boundary: it stores the generator, static
depictions, and an append-only ledger of approved release tags. Generated APT
indexes and `.deb` files are assembled into the Pages artifact and are not
committed to either repository.

The generator accepts separate `rctl_<version>_iphoneos-arm.deb` (rootful) and
`rctl_<version>_iphoneos-arm64.deb` (rootless) artifacts from immutable public
GitHub Releases. Both retain package identifier `com.greatlove.rctl`; they are
not a universal DEB. The generator verifies release and asset attestations, release
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

### Rootless admission

The distribution repository additionally owns `rootless-releases.txt`, an
explicit subset of the approved tags in `releases.txt`. It is initially empty.
The ordinary synchronization step does not automatically approve rootless
delivery. Add a tag only after its immutable release includes:

- `rctl_<version>_iphoneos-arm64.deb` and its `SHA256SUMS` entry.
- An attested `rctl-qualification_<version>_iphoneos-arm64.json`, schema 4,
  with matching `product`, `tag`, and `version`.
- `package: {name, architecture, sha256}` bound to that exact rootless artifact.
- Boolean checks `rootless_runtime`, `package_manager_install`,
  `package_manager_upgrade`, and `package_manager_recovery`, all true after
  physical-device validation. Every other reported check must also be true.

Rootless has no bootstrap exemption. Its validator additionally checks the
`/var/jb` layout, non-empty web client, maintainer-script prefix, ElleKit and
firmware dependencies, and absence of prefixed or unprefixed relay secrets.
The release generator in this monorepo still produces rootful release sets;
rootless immutable release assembly and physical APT qualification are pending.
The experimental `~rootless` builds are not substitutes for those release assets.

`Release` and depictions derive their architecture list from the actual verified
`Packages` index, not from the list of architectures the generator can validate.
Consequently adding generator support alone does not make the current rootful
feed installable on Dopamine. The distribution tests cover both layouts and
reject renamed rootful DEBs, mismatched reports and corrupt checksums.

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
