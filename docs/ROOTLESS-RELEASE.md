# Rootless Release Readiness

## Current Baseline (2026-09-12)

This is a release-preparation audit, not a release qualification certificate.
The operator confirms that Talk now works and that the device functions they
tested work. Do not reopen the resolved Talk issue merely because older notes
still contain an incomplete microphone test matrix. That confirmation does not
establish an updater transaction or recovery test.

Read-only checks of the physical rootless device and deployed relay established:

- The current test package is `install ok installed`, architecture
  `iphoneos-arm64`, built from the `58a27cf` Talk fix.
- Both approved devices are online. The relay's authenticated device tunnel
  reports `update.transactional` for rootful, but not for rootless.
- The deployed relay reports `update_configured: false`. In a real Chrome admin
  session, opening each device's actions menu showed no Update action.
- Directly invoking the installed rootless updater's envelope-verification
  mode exits before verification with its explicit qualification rejection.
- No package replacement, respring, relay configuration change, or VPN change
  was performed during this audit.
- GitHub currently lists `v0.3.2` as the latest published release; `v0.3.3` and
  `v0.3.4` are drafts. A draft is not a verified public rollback source.

Host verification passed for `internal/setup`, `cmd/rctl-setup`, `internal/deb`,
and `cmd/rctl-update-manifest`. The relay updater preflight regression covers
disabled configuration, offline and unapproved devices, missing updater
capability (including the current rootless feature set), and an already-current
device. Each case asserts the exact rejection before a device tunnel is used.
These tests do not replace physical installation or rollback acceptance.

## Existing Components

The Go wizard already exists in `relay/cmd/rctl-setup`. Its lifecycle includes
install, preflight, doctor, upgrade, backup, restore, recover, uninstall, and
admin reset. Creating another wizard is not release work.

There are three different update paths:

1. `rctl-setup upgrade` replaces a managed relay deployment.
2. Sileo/APT installs or upgrades the public device package.
3. Relay admin Update launches the device's detached transactional updater.

Success on one path does not qualify either of the others. In particular, the
existing rootless personalized-package generator and successful enrollment do
not enable the rootless transactional updater.

## Remaining Integration Work

| Boundary | Current implementation | Required change and proof |
| --- | --- | --- |
| Device admission | `Capabilities.mm` omits `update.transactional`; `UpdateLauncher.mm` and `updater/main.mm` reject rootless | Retain these gates until the complete rootless transaction and recovery path is tested |
| Native updater | Key, executable, dpkg tools and launchd paths are rootful; daemon reload uses `unload/load` | Use the existing package/runtime path conventions; verify actual Dopamine launchd and SpringBoard lifecycle after dpkg exits |
| Artifact selection | Signed schema 1 identifies artifacts by version only; native `packageMatches` checks ID/version, not architecture | Bind selection and DEB verification to architecture/layout; explicitly reject cross-lane target and rollback artifacts; preserve old rootful clients |
| Catalog availability | No catalog is configured on the deployed relay | Publish exact clean target and rollback artifacts to trusted HTTPS, verify the pinned signature, then explicitly configure the qualification channel |
| Wizard packaging | Setup stages one `PublicPackage`; bootstrap expects the rootful asset | Deliver and preserve both public base variants through install, upgrade, backup, restore, and recovery; reuse the existing wizard |
| Release pipeline | Draft, release assembly and catalog verifier require `iphoneos-arm` | Build both lanes using the common builder, and include both in the signed/provenance-verified release and APT admission |
| Candidate identity | Test DEB version includes a timestamp while the running daemon reports the version from `control` | Reconcile exact package identity and runtime version checks before testing; current updater matching does not strip `~test` versions |

Do not combine two same-version architectures in schema 1: the producer rejects
duplicate versions, and existing native clients select the first matching
version. Do not bypass this with renamed archives or changed control metadata.

The rootless package scripts deliberately defer the GUI restart until the
package-manager transaction ends. A detached updater must own that restart;
simply applying `/var/jb` to the rootful paths is insufficient.

## Next Physical Acceptance

After implementing and host-testing these boundaries:

1. Bootstrap one audited updater-capable rootless candidate with physical
   recovery available. The currently installed updater cannot update itself
   through a path it deliberately refuses to start.
2. Prepare a signed target plus an exact clean rollback package for the
   installed candidate. Never use a personalized DEB as a public rollback asset.
3. Use the real relay admin Update action and confirmation. Verify the queued
   job, completed dpkg state, new package/runtime version, SpringBoard IPC,
   reconnection with the same relay identity, and preserved LAN policy.
4. Perform an explicitly scheduled controlled failure/recovery test with local
   access available. Confirm rollback restores the prior version and identity.
5. Recheck rootful update compatibility, then admit the exact release artifacts
   to the release and APT workflows. Do not mark an unperformed check passed.

## Version Decision

Prepare `0.4.0` as the next feature release, without creating a tag yet. Rootless
support and the accumulated features justify a minor increase over `0.3.x`;
they do not by themselves establish the support guarantees of `1.0.0`. Keep the
wire protocol major unchanged unless an actual incompatible contract requires
a migration. Do not replace or retag existing release artifacts.

Local candidate DEBs may use `0.4.0~rc.N` only after the candidate-identity issue
above is resolved. The current GitHub draft workflow accepts `vMAJOR.MINOR.PATCH`
tags only; do not assume it already supports `v0.4.0-rc.N` tags.
