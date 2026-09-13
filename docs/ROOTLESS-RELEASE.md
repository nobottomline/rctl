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

### Ordinary Build and Final State

After removing the compile-time qualification flag, the ordinary builder
produced `0.4.0~rc.3` from commit `f1b17cb`. It passed the public package audit
and was installed from RC2 using the same admin Update/Start update buttons.
The job completed, dpkg and runtime agreed on RC3, and identity and SpringBoard
IPC checks passed again. This was not the rollback-test artifact.

- An independent LAN browser on RC3 decoded 170 additional frames in three
  seconds. Relay control decoded new frames on both the rootless and rootful
  devices after the final relay restart.
- The temporary update-channel drop-in was removed, both relay/proxy services
  were checked active, and unrelated service processes remained unchanged.
- All exact qualification files, including the intentional fault fixture, were
  withdrawn from the public HTTPS directories. Private backups and clean local
  candidate artifacts remain available for recovery.
- Both deployed update channels are unconfigured until an actual release feed
  is admitted; the admin Update menu is therefore hidden intentionally. The
  rootless device still advertises updater support and its last job is complete.
- No stable tag, GitHub release, APT publication, or push was performed.

| Boundary | Current implementation | Required change and proof |
| --- | --- | --- |
| Device admission | Ordinary builds advertise rootless transactional update support | Runtime update and watchdog recovery passed; qualify the exact release artifacts before publication |
| Native updater | Bootstrap-aware paths, exact installed package checks, rootless launchd bootstrap and explicit post-dpkg SpringBoard restart implemented | Update and recovery passed on Dopamine/iPadOS 15.5; other bootstrap variants remain unqualified |
| Artifact selection | Rootful schema 1 preserved; rootless schema 2 signs architecture; producer audits public layout and native checks exact ID/version/architecture | Cross-lane, malformed and duplicate-version host tests pass; valid schema-2 update/recovery passed physically |
| Catalog availability | Temporary signed channels passed and were removed; no stable catalog is configured on the deployed relay | Publish and qualify the exact release feed before enabling it |
| Wizard packaging | Existing wizard/bootstrap now accept both public bases; owned paths cover backup, restore and recovery; upgrades require replacement sources | Go tests and checksum-failure bootstrap tests pass; fresh-host acceptance remains pending |
| Release pipeline | Draft/publish workflows require both architectures and separate signed catalogs; first rootless release can seed a target-only catalog | Actionlint passes; actual release assembly, provenance and APT admission remain release gates |
| Candidate identity | Optional `package_version` in capabilities and relay hello carries the exact Debian version, independently of daemon product version | Exact RC2/RC3 identity was verified after UI-initiated updates |

Do not combine two same-version architectures in schema 1: the producer rejects
duplicate versions, and existing native clients select the first matching
version. Do not bypass this with renamed archives or changed control metadata.

The rootless package scripts deliberately defer the GUI restart until the
package-manager transaction ends. A detached updater must own that restart;
simply applying `/var/jb` to the rootful paths is insufficient.

## Clean-Host Engineering Rehearsal (2026-09-13)

A newly provisioned Ubuntu 26.04 amd64 VPS with 2 GiB RAM was exercised with
both clean public package architectures. The baseline was `bc0e0aa`; private
`0.4.0`/`0.4.1` fixtures tested lifecycle version transitions without creating
tags, releases, or APT entries. The image was built on the test host and served
by a loopback-only registry, not a public attested release registry. No GitHub
credential or device-update signing key was copied to the server.

Observed acceptance:

- Fresh preflight reported stale DNS and missing Docker/Compose without
  creating a deployment. After prerequisites and DNS propagation, the local
  checksum bootstrap installed both public bases, obtained trusted HTTPS, and
  verified authentication and persistence across a relay restart.
- Repeating bootstrap preserved byte-identical environment and ownership
  files. Doctor passed the managed services and public routes.
- Real browser `Pair device` / `Download package` buttons produced both
  rootful and rootless private packages. Both returned `201` with `no-store`;
  anonymous package generation returned `401`.
- A test enrollment was created, backed up, deleted through the API, and
  restored. Browser readback proved its absence before restore and presence
  afterward. Both public bases and environment hashes were preserved.
- The newer server fixture upgraded both bases and retained the test record.
  An intentionally wrong runtime version rolled back automatically. Killing
  only the active wizard during post-apply verification left a checkpoint;
  another upgrade was rejected until `recover` restored the prior deployment.
- Admin reset invalidated the prior browser session, admitted the new secret,
  and preserved the TURN secret. Keep-data uninstall retained the database;
  restore returned the healthy deployment and the same rootless base.
- Delete-data uninstall removed the live data and both public bases. Its
  retained recovery archive passed the uninstalled-state restore dry run.

The external TURN test exposed a real configuration defect: `listening-ip=0.0.0.0`
without an explicit relay bind made coturn use the wildcard as its relay
address. With public/private reverse mapping, same-server peers were rejected
with `CHANNEL_BIND 403 Forbidden IP`. STUN health and successful allocation
alone did not catch this. The wizard now renders a concrete relay bind and
explicit public/local mapping, validates its local-interface ownership in
preflight, and preserves the peer ACLs. The corrected managed deployment passed
browser relay-only DataChannel echo over both UDP and TCP. The independent
coturn client sent and received 20/20 messages per transport with zero loss.

After delete-data, the previous backups were reserved outside managed paths
for another fresh-install attempt with the corrected wizard. Preflight first
rejected a diagnostic TURN allocation still occupying a relay port. After that
diagnostic container was removed, installation reached public verification but
failed with a remote TLS internal error after two minutes. Install rolled back
and bootstrap retained the previous setup binary. The precise ACME/TLS cause
was not established in this time-limited run; do not count corrected-wizard
fresh issuance or renewal as passed. Successful TURN evidence above comes from
the verified managed upgrade, not this failed fresh-install attempt.

This is not a schema-4 publication report. Physical iPad enrollment/control
through this temporary relay, iPad forced-TURN media, ACME renewal, NAT-host
acceptance, and exact final draft provenance remain unverified by this run.
The working VPS, existing iPad bindings, and VPN were not changed.

Post-rehearsal installer hardening was verified locally: failed container stops
now retain deployment data and the recovery checkpoint, including during
explicit recovery of an interrupted upgrade. Failed service verification saves
a bounded, allowlisted Caddy/ACME diagnostic report before rollback. Tests cover
failed stop/retry/recover, cleanup failure, cancellation, diagnostic collection
failure, secret-field exclusion, and symlink rejection. Full relay tests, setup
race tests, setup vet, and a Linux amd64 setup build passed. These checks do not
resolve the preceding TLS incident or substitute for a new live acceptance run.

After the operator confirmed the test VPS rental was extended, a fresh install
was repeated with setup `1f9ac8d` and the same private `0.4.1` package/image
fixtures. Bootstrap completed successfully, activated the candidate setup
binary, and doctor passed trusted HTTPS/WebSocket, ownership, service health,
and permissions. Chrome UI login and both package download buttons passed
again (`201`, `no-store`); anonymous generation returned `401`. Browser
relay-only DataChannel echo passed on both UDP and TCP, with both selected
candidates confirmed as relay candidates. The earlier TLS error did not recur;
its original cause is still unknown. This adds corrected-wizard fresh-install
evidence, not public provenance, certificate renewal, or physical iPad acceptance
on this new host. Existing device bindings were not modified for these checks.

## Physical Device Supplement (2026-09-13)

The existing Dopamine/iPadOS 15.5 device stayed on `0.4.0~rc.3`. An enrollment
from the temporary server's UI-generated rootless package was added as a second
relay entry after backing up the configuration. This was a runtime integration
test, **not** installation of the private `0.4.1` package on the device.

- `Approve device` and `Open control` were exercised through Chrome UI against
  the exact physical device identity. The screen decoded 600 new frames over
  ten seconds; a root-terminal command through the UI returned successfully.
- Browser-only relay policy with TURN/UDP selected a local relay candidate and
  a device server-reflexive candidate, decoding 600 frames over ten seconds.
  This proves one relayed leg, not both-peer relay-only acceptance.
- Console `Capture` produced a decoded 2732x2048 screenshot preview and exposed
  its separate save action. The Files modal opened; no destructive file or
  media action was performed.
- Browser-only TURN/TCP repeatedly failed to connect. Allocations produced
  local relay candidates with `relayProtocol=tcp`, but sampled ICE checks had
  zero responses and peers repeatedly closed/reconnected. Device candidates
  included host/server-reflexive candidates and, in a later attempt, relay.
  Extending only the test page's 7-second timer did not establish a connection.
  Two-browser mixed UDP/TCP TURN echo passed in both directions, isolating this
  from a general mixed-transport server failure. The subsequent diagnosis is
  recorded below; no production timeout, ICE backend, or VPN was changed.
- `Revoke access` disconnected an active peer, marked the temporary device
  revoked/offline, and made its proxied capabilities request return `404`.
  The temporary record was then deleted through the UI.
- The temporary relay entry was removed with a compare-before-replace guard.
  The original DeviceID, relay secret, and LAN policy were preserved. After the
  daemon restart, the permanent relay decoded 601 new frames over ten seconds
  and LAN decoded 169 new frames over three seconds. No SpringBoard restart,
  package replacement, or VPN change was needed.

### TURN/TCP Diagnosis and RC4 Candidate

An isolated browser peer without automatic reconnection reproduced the failure
before the video-start watchdog. In-memory STUN inspection confirmed that the
browser sent an authenticated Binding request containing `ICE-CONTROLLED` with
a zero tie-breaker. The native peer returned `400`: pinned libjuice used the
numeric role values to infer whether the attributes were present, so it treated
the present zero-valued attribute as missing.

Commit `a807605` separates attribute presence from value in the pinned dependency
and corrects the controlled-role conflict comparison. It retains authentication
and rejects missing or simultaneous role attributes and invalid nomination.
The patch does not change VPN configuration or add native TURN/TCP support.

Verification completed before device installation:

- Authenticated host loopback tests cover zero and nonzero role values, missing
  and duplicate roles, role conflicts, invalid nomination, and wrong passwords.
- Both iOS library architectures rebuilt successfully; packaging checks the
  applied patch digest to reject stale native libraries.
- Native host tests and release-workflow lint passed. Both public
  `0.4.0~rc.4` package architectures built and passed the public package audit.

Physical RC4 installation and browser/device TURN/TCP acceptance remain pending.
The regression tests and candidate builds alone do not close the release gate.

## Remaining Release Gates

1. Repeat the clean-host wizard/device acceptance with the exact draft assets
   and anonymously pullable candidate image. The September 13 engineering
   rehearsal above covers the dual-package server lifecycle, not final artifact
   provenance, renewal, or the complete device package-install/enrollment path
   through that new host.
   Resolve the browser/device TURN/TCP failure above and verify both-peer
   relay-only media/control; neither is satisfied by the two-browser echo test.
2. Prepare the exact version-matched `0.4.0` candidate set and provenance.
   Re-run the required release matrix for both package architectures, including
   package-manager upgrade/recovery and rootful transactional compatibility.
   The RC tests above cannot sign off different final artifact hashes.
3. Record only completed schema-4 qualification checks, then publish through
   the guarded release/APT workflows. Never use a personalized DEB as a public
   artifact or omit the installed-version rollback source from an update feed.

## Version Decision

Prepare `0.4.0` as the next feature release, without creating a tag yet. Rootless
support and the accumulated features justify a minor increase over `0.3.x`;
they do not by themselves establish the support guarantees of `1.0.0`. Keep the
wire protocol major unchanged unless an actual incompatible contract requires
a migration. Do not replace or retag existing release artifacts.

Local qualification DEBs use `0.4.0~rc.N` with exact package identity. The
GitHub draft workflow accepts `vMAJOR.MINOR.PATCH`
tags only; do not assume it already supports `v0.4.0-rc.N` tags.
