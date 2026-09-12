# Rootless Release Readiness

## Initial Audit (2026-09-12)

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

## Implementation and Qualification (2026-09-12)

The updater-capable `0.4.0~rc.1` bootstrap is now installed on the physical
rootless device. The operator installed it through Filza and restarted
SpringBoard. Independent dpkg inspection reports `install ok installed` and
`iphoneos-arm64`; the authenticated relay tunnel advertises the updater. This
is bootstrap proof, not yet a relay-initiated update or rollback.

### Relay Update Acceptance

The subsequent RC1 to RC2 transaction passed through the real relay admin UI:
`Device actions` -> `Update device...` -> `Start update`. No SSH package-install
command replaced this path. The button was available only for the rootless
qualification lane; the rootful device's unconfigured update action stayed
hidden.

- The ECDSA-verified schema-2 catalog contained both exact clean public RC DEBs.
- The observed job progressed through download and runtime verification to
  terminal `complete`, from `0.4.0~rc.1` to `0.4.0~rc.2`.
- Independent SSH inspection returned `install ok installed`, exact version
  `0.4.0~rc.2`, and `iphoneos-arm64`.
- Capabilities reported the exact new package version; SpringBoard device-info
  IPC succeeded through the authenticated relay tunnel.
- The approved device set did not change. Persistent relay identity entries
  compared equal before and after the transaction without exposing them.
- The unmanaged relay candidate had a binary/configuration/SQLite backup, and
  its HTTPS, admin assets, database integrity and both device tunnels passed.
  The existing control client and unrelated services were unchanged.

Both RC2 package architectures built and passed the public package audit.
`make test`, the complete Go suite, admin lint/build and release workflow
actionlint passed. These checks do not establish clean-host wizard qualification
or acceptance of a future immutable `0.4.0` artifact set.

### Recovery Acceptance

A separate signed qualification catalog paired clean RC2 with
`0.4.0~rc.3+rollback-test`. Only the test DEB's package metadata version changed;
the functioning runtime still reported RC2. This deliberately failed exact
post-install version verification without introducing broken executable code.
It was never a GitHub Release or APT artifact.

- Runtime-verification failure restored RC2 automatically and reconnected.
- In the watchdog test, the same admin Update flow reached `verifying` with
  the test target fully configured in dpkg. Through the real Root Terminal UI,
  the operator harness terminated only the `--run` process whose request path
  matched the current job, leaving its independent watchdog alive.
- The watchdog transitioned to `rolling_back`, then terminal `rolled_back`.
  Independent dpkg inspection confirmed RC2 `install ok installed`; relay
  identity, the approved device set, and SpringBoard IPC were preserved.
- The normal RC2 catalog was restored as soon as the test job had selected its
  target, before package replacement. No other device received the test feed.

The temporary rootless build gate is removed on this evidence. It does not
establish recovery from power loss, a hung dpkg subprocess, or every possible
bootstrap failure. The rootful/rootless release matrix and clean-VPS wizard
acceptance still apply to the exact future tagged artifacts.

| Boundary | Current implementation | Required change and proof |
| --- | --- | --- |
| Device admission | Ordinary builds advertise rootless transactional update support | Runtime update and watchdog recovery passed; qualify the exact release artifacts before publication |
| Native updater | Bootstrap-aware paths, exact installed package checks, rootless launchd bootstrap and explicit post-dpkg SpringBoard restart implemented | Update and recovery passed on Dopamine/iPadOS 15.5; other bootstrap variants remain unqualified |
| Artifact selection | Rootful schema 1 preserved; rootless schema 2 signs architecture; producer audits public layout and native checks exact ID/version/architecture | Cross-lane, malformed and duplicate-version host tests pass; physical acceptance pending |
| Catalog availability | No catalog is configured on the deployed relay | Publish exact clean target and rollback artifacts to trusted HTTPS, verify the pinned signature, then explicitly configure the qualification channel |
| Wizard packaging | Existing wizard/bootstrap now accept both public bases; owned paths cover backup, restore and recovery; upgrades require replacement sources | Go tests and checksum-failure bootstrap tests pass; fresh-host acceptance remains pending |
| Release pipeline | Draft/publish workflows require both architectures and separate signed catalogs; first rootless release can seed a target-only catalog | Actionlint passes; actual release assembly, provenance and APT admission remain release gates |
| Candidate identity | Optional `package_version` in capabilities and relay hello carries the exact Debian version, independently of daemon product version | Verify exact RC identity after the relay transaction |

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

Local qualification DEBs use `0.4.0~rc.N` with exact package identity. The
GitHub draft workflow accepts `vMAJOR.MINOR.PATCH`
tags only; do not assume it already supports `v0.4.0-rc.N` tags.
