# Rootless Release Readiness

## Current Checkpoint (2026-09-14)

The rootless device now has an installed pacing test prerelease,
`0.4.0~test.20260913215953.2b9be9d6c194`. It regressed remote-screen playback
even on direct ICE and is not acceptable for release. The exact draft `0.4.0` previously passed
the UI update and external-watchdog rollback tests described below; those
results do not qualify the new prerelease.
The rootful device remains on `0.3.4-24+debug`. No always-on display or keepalive
behavior was added; the earlier black capture coincided with the physical
display switching off and is distinct from the packet-loss symptom below.

Both public `0.4.0` package variants now pass the draft checks below. The
temporary server now runs the exact GitHub candidate after a clean install,
repeated bootstrap, trusted admin UI, package downloads, and browser TURN
checks. Exact-candidate backup/restore, admin reset, and both uninstall/restore
paths now pass. Renewal is blocked by an ACME rate limit, while managed upgrade
and interrupted recovery still need exact-candidate acceptance. Forced-TURN
device media has a new unresolved failure described below. The
`v0.4.0` tag and GitHub draft exist; no stable release or APT publication has
occurred. The
[remaining gates](#remaining-release-gates) distinguish this
preparation from exact-artifact acceptance; older sections below are historical.

### Exact Draft Verification

The draft is bound to `92f450e529a9e1a80ea9f996773ff5cb757e6e2c`.
[CI](https://github.com/nobottomline/rctl/actions/runs/34770984859),
[CodeQL](https://github.com/nobottomline/rctl/actions/runs/34770984444), and
the [draft workflow](https://github.com/nobottomline/rctl/actions/runs/34771064286)
completed successfully. An earlier Ubuntu test failure was corrected by
explicitly building test DEBs with gzip instead of relying on the host's
compression default; the runtime archive policy was not broadened.

Independent checks of the downloaded draft passed:

- Exactly ten expected files, repository/workflow/tag/source-bound provenance
  for every file, and all SHA256 checksums.
- Both `0.4.0` public DEBs, including package identity, architecture, and the
  public-package audit.
- Both signed update catalogs against the pinned key. The rootful catalog
  includes verified `0.3.0` and `0.3.2` rollback artifacts; the first rootless
  stable catalog contains only its `0.4.0` target.
- Candidate OCI provenance, anonymous index access for Linux amd64/arm64,
  and a nonempty BuildKit SBOM. The index digest is
  `sha256:08b159983f2c399b4455bb926e3e01481f5ebf43a7c34f5f106dc42c06c2603e`.
- On the temporary Linux amd64 host, the downloaded setup binary reported the
  exact version/source, release-set assembly reproduced `SHA256SUMS` byte for
  byte, and an empty Docker configuration pulled the pinned image anonymously.

These artifact checks alone do not establish device acceptance of the final
bytes. In particular, the former rootless RC4 and current rootful debug
build are absent from the public rollback catalogs. Their update tests require
separate signed qualification catalogs with the exact clean installed-version
DEBs; do not substitute a different package version or publish those test feeds.

### Exact Candidate Server Check

The temporary host had zero enrolled devices and passed SQLite integrity
checks before its engineering deployment was removed through the wizard.
The uninstall's recovery archive passed restore validation and was retained
outside the fresh-install paths; no unrelated services or images were removed.

- Staged, checksum-verified draft bootstrap installed `0.4.0` from the embedded
  candidate digest with both package lanes. Trusted HTTPS and doctor passed.
- Repeating bootstrap preserved byte-identical environment and ownership
  files; doctor passed again.
- Real Chrome admin buttons generated and downloaded both personalized package
  variants (`201`, `no-store`); anonymous generation returned `401`. The two
  unused test enrollments were revoked/deleted and private downloads removed.
- Off-host browser DataChannel echo passed for UDP and TCP with both peers
  restricted to relay candidates. This is not physical-device media proof.

Device update channels remain disabled on this temporary server while the
release is a draft. The permanent relay, its device bindings, and VPN were
not modified. No schema-4 publication report has been signed off.

### Exact Candidate Lifecycle and Device Update

The downloaded `0.4.0` setup binary passed these additional managed-host tests:

- Backup and actual restore preserved the environment and both public package
  hashes. An enrollment marker created, deleted, and recovered through the
  admin UI independently demonstrated database restoration.
- Admin reset invalidated the previous browser session (`401`), accepted the
  new credentials, rotated admin/session secrets, and preserved the TURN secret.
- Both keep-data and delete-data uninstall paths were followed by actual
  restoration and doctor checks. Recovery archives were retained; deleting
  the live deployment was not treated as proof of successful recovery.
- A controlled production renewal attempt returned an ACME rate limit. The
  existing trusted certificate and Caddy were restored and doctor passed.
  Further production attempts were stopped. The earlier fixture renewal is
  not evidence of successful exact-candidate renewal.

Updater qualification used a separate, temporary relay with the exact candidate
image, its own database, and private architecture-specific signed catalogs.
The managed deployment's update channels remained disabled. A diagnostic
additional device binding preserved the permanent binding; this setup is not
proof of personalized-package installation through Sileo.

- Real admin UI `Update device` / `Start update` upgraded rootless RC4 to the
  exact clean draft `0.4.0` DEB. The job completed, dpkg reported
  `install ok installed` / `iphoneos-arm64`, and the device identity, existing
  relay credentials, and SpringBoard IPC were preserved.
- The initial post-update UI check delivered 594 additional frames, submitted
  Control/Home commands over the control DataChannel, loaded a 2732x2048
  screenshot preview, and opened Files.
- A private fault package declared `0.4.1~rollback-test` but retained the exact
  final runtime data archive. After full installation reached verification,
  only the matching updater worker was terminated, leaving its external
  watchdog alive. The job reached `rolled_back` and restored exact `0.4.0`,
  with clean dpkg state, the same identity/bindings, and working SpringBoard IPC.
  The normal catalog was restored and the fault DEB removed from HTTP serving.

### Post-Rollback Transport Finding

After the operator unlocked the device, a forced-TURN/TCP browser displayed
the actual home screen. However, repeated TCP and UDP runs then decoded very
few or no additional frames while ICE/DTLS remained connected. One TCP sample
received 611 additional frames but decoded only one over ten seconds; cumulative
packet loss increased from 4 to 231 and PLI requests from 6 to 29. A screenshot
UI check also timed out. Successful command submission alone does not prove
its visible effect during this failure.

The symptom also reproduced using the permanent signaling relay with the
browser still forced through the temporary TURN server. An independent LAN
check of final `0.4.0` delivered 163 frames in three seconds. The temporary
relay/proxy/TURN containers were not CPU- or memory-saturated at inspection.
These observations narrow the failing path but do not prove its root cause;
neither VPN nor runtime settings were changed to conceal it. A harness exit
success based on a single new decoded frame is not sustained-video acceptance.
Forced-TURN media and reconnect remain release blockers.

Follow-up on September 14 reproduced interval stalls on the unchanged `0.4.0`
package. Removing playout-delay constraints only in the test browser improved
decoding but did not eliminate the stalls. Existing Saver mode delivered 479
new frames over twenty seconds, with at least ten decoded frames in every
two-second sample. That is a useful comparison, not proof of smooth motion or
all-profile acceptance. The device logged PLI handling and new keyframes; the
temporary TURN host's UDP receive/send-buffer error counters were zero.

A separate deterministic regression test found that the production packetizer
could exceed a 1280-byte packet after RTP extensions, SRTP, TURN, IPv6 and UDP
overhead. Main now limits H.264 fragments to 1100 bytes for both video tracks;
the actual production-chain test fails before the change and passes afterward,
including payload/marker integrity and session teardown. See the
[packet budget](TRANSPORT.md#video-packet-budget). This is a verified sizing
defect, not a sufficient fix for the observed stalls. Both local package
lanes built and passed the public audit. The rootless prerelease was transferred
with matching local/device SHA-256, installed by the operator, and independently
reported `install ok installed` / `iphoneos-arm64`. These are not the existing
tag-bound draft, and no release asset or
tag was replaced. The draft workflow now runs the native packet-budget,
authorization/teardown, and Talk queue tests before either package build;
workflow lint passed locally, but the updated GitHub job has not run yet.

Ordinary control through the permanent relay, with direct ICE permitted,
subsequently delivered 443 new frames over ten seconds and loaded the native
screenshot and Files. This is not an off-LAN or forced-TURN acceptance result.

### Packet-Sizing Prerelease Comparison

On the installed prerelease, LAN decoded 181 additional frames in three seconds.
A separate real browser displayed actual device content, loaded the screenshot
preview with its Save link, and restored visible video after a page reload.

The following thirty-second runs used permanent signaling, temporary browser
TURN, and relay-only candidates on both peers. No profile downgrade, VPN change,
or signaling-timeout override was used. Each run failed the minimum requirement
of ten additional decoded frames in every two-second sample:

- TURN/TCP: 1028 additional decoded frames overall, but multiple stalled
  intervals; PLI increased from 0 to 45 while ICE/DTLS stayed connected.
- TURN/TCP with playout constraints removed only in the test browser: 1407
  additional frames, but still a stalled interval; PLI increased from 0 to 14.
  This diagnostic override was not added to the product.
- TURN/UDP: 550 additional frames overall, with repeated stalled intervals;
  PLI increased from 2 to 51 while ICE/DTLS stayed connected.

Reported cumulative loss returned to zero after some retransmissions; this is
not evidence of loss-free delivery. The first sustained stalls in both TCP
runs occurred near frame 600, consistent with the configured ten-second GOP
at 60 fps. Device logs confirmed repeated recovery keyframes around 116 KB.
This is a correlation, not proof of the cause. Inspect burst delivery and
keyframe recovery before further buffer tuning; do not add an unbounded pacer
or drop arbitrary parts of an access unit to hide the failure.

A subsequent ordinary permanent-relay session selected direct ICE, decoded
401 additional frames in ten seconds, and loaded the screenshot and Files.
It also reported dropped frames and additional PLI, so it is not smooth-video
acceptance and does not close the forced-TURN gate.

The LAN UI exposed a separate build defect: stale `web/dist/index.html` carried
browser version `0.3.4` into this test package despite product version `0.4.0`.
Package staging now always rebuilds the client and stops on build failure.
Regression tests execute the real staging recipe for both lanes, proving stale
HTML is refreshed and cannot mask a failed build. Both replacement local DEBs
built, passed the public audit, and contain byte-identical fresh client HTML.
Those replacements have not been installed or published; the device remains on
the packet-sizing prerelease above.

After these comparisons, the live relay configuration matched the retained
pre-install snapshot byte-for-byte, dpkg audit was clean, and the temporary
private snapshot was removed. All test viewers were closed; no permanent
binding or VPN setting was changed.

### Bounded Pacing Candidate

A subsequent header-only capture on the temporary TURN host retained only
link/IP/UDP/RTP headers in memory, not media payloads or a saved capture file.
It covered 1312 frames and 2684 packets with no capture-kernel drops. Some
complete large frames arrived within 80 ms; others required 687-1110 ms and
25-36 repeated packets. Zero remaining sequence gaps after repair does not mean
the initial delivery was loss-free. A simultaneous ordinary-profile TURN/TCP
run still stalled despite connected ICE/DTLS. This supports investigating burst
delivery and repair deadlines, not attributing the fault to rootless or VPN.

The next local candidate adds bounded remote-screen pacing and leaves remote
playout timing to the receiver; see `TRANSPORT.md`. Both package lanes built
and passed public-artifact audits. The focused native transport suite, all 43
web tests, web build, and `make test` passed. The rootless package was transferred
with matching SHA-256 for operator installation. No draft tag, published asset,
permanent relay client, binding, or VPN setting has been replaced.

The operator installed the candidate and restarted SpringBoard. Independent
inspection confirmed its exact version and `install ok installed`. The new
client was supplied only inside an isolated browser context after fetching the
authorized control page and retaining its server-generated bootstrap and
security headers; permanent relay files were not changed.

All three thirty-second comparisons failed the sustained-frame requirement:
TURN/TCP advanced 104 frames, TURN/UDP 130, and ordinary direct ICE 97. Direct
ICE initially had approximately 8 ms RTT with zero reported packet loss, yet
still stalled. Therefore the pacing candidate itself has a regression; neither
VPN nor rootless can be blamed based on these runs. The unchanged LAN path
advanced 165 frames in three seconds, a smoke pass rather than a full soak.

A follow-up diagnostic build counts queue expiry, overflow, send exceptions and
send duration at session teardown without logging media, secrets or device
identities. Native transport tests and its rootless package audit pass; runtime
diagnosis remains pending. The maximum tick interval includes idle time and must
not alone be interpreted as scheduler lateness. Do not publish this candidate
or promote its pacing policy until the direct-path regression is understood.

### Qualification Cleanup

The temporary device access was revoked through the admin UI: its active peer
disconnected and the device tunnel returned `404`. Only the added test binding
was removed from the device; the original configuration was restored
byte-for-byte and dpkg audit was clean. The revoked test device was then deleted
through the UI. Private configuration snapshots were removed from the device
and local staging.

The isolated relay/proxy containers, their separate database, test catalogs,
and secrets were removed. The managed deployment's ownership file was unchanged,
its three services remained running, and doctor passed; recovery backups were
retained. No permanent-relay configuration, VPN setting, release asset, or APT
publication was changed.

After cleanup, another permanent-relay browser session decoded 603 additional
frames over ten seconds with no reported RTP packet loss. The screenshot preview
showed actual device content and Files opened. At that checkpoint the device
was on `0.4.0` with its original identity. This closes the test cleanup, not the outstanding
forced-TURN or complete release matrix.

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

### RC4 Physical Transport Verification

Independent package inspection confirmed `0.4.0~rc.4` on the rootless device.
The following checks ran with the existing permanent relay identity, a temporary
TURN server for the browser, and the permanent TURN server for the device. No
VPN change, native ICE-server reconfiguration, or timeout extension was used.

- Browser TURN/TCP to a device server-reflexive candidate connected with DTLS
  and decoded 299 additional frames over five seconds. The prior STUN `400`
  did not recur; TURN's initial authentication challenge was expected.
- With browser policy set to relay-only and non-relay remote candidates rejected,
  both selected candidates were relay candidates. The ordinary control UI
  remained on one connected peer through 65- and 90-second TCP checks, with
  decoded frame counts increasing. The 90-second check decoded 2358 more frames.
- The same forced-relay UI check over browser TURN/UDP decoded 594 more frames
  over ten seconds. Candidate gathering reported two `701` errors, but the
  selected relay pair remained connected and delivered media.
- UI `Control` and `Home` emitted three messages on the actual control
  DataChannel. Console `Capture` returned a decodable 2732x2048 image with a
  save action, and the Files modal opened. These do not prove the visible
  effect of the input commands or file transfer.
- An independent LAN browser reported RC4 and decoded 170 new frames over
  three seconds with relay configuration still installed.

The decoded screen and native screenshot were black during visual inspection.
The device's unlocked/display-on state was not independently established; the
operator was asked to unlock it. Therefore transport connectivity and decoding
are confirmed, but visible screen content and input effects still need an
unlocked-device check. Do not treat black decoded frames as complete media or
control acceptance.

One earlier UI run could not identify a nominated pair in its final statistics
sample. The diagnostic was corrected to use the transport's
`selectedCandidatePairId`, with nomination as a fallback. Later long runs
recorded no ICE failure, peer replacement, or signaling closure. This was a
test-harness change, not a production reconnect-policy change.

Full Go tests, relay/setup/personalization race tests, Go vet, the 43 web-client
tests, both web builds, admin lint, the isolated relay smoke test, and audits of
both RC4 DEBs passed. Final immutable release hashes remain unqualified.
The Root Terminal UI independently confirmed clean dpkg configuration and a
byte-identical persistent relay configuration after installation and testing.
The private diagnostic configuration copy was then removed; the live
configuration and VPN were left unchanged.

### Unlocked Visual Follow-up

After the operator confirmed unlocking the iPad, the ordinary control UI over
forced TURN/TCP showed the device's application and the actual iOS Control
Center after clicking `Control`. Clicking `Home` dismissed Control Center;
the subsequent native screenshot showed the application again. Both selected
ICE candidates were relay candidates and the UI actions used the control
DataChannel. This establishes visible screen and input effects for that session,
not merely decoded frames or successful command submission.

A following forced-TURN/UDP run decoded 427 additional frames over ten seconds
and loaded the native screenshot and Files UI. After reloading the control
page, ICE and frame delivery recovered, but a video-pixel check found a black
image. An independent LAN session then reproduced black video in three samples
five seconds apart, with `readyState=4`, a playing 1024x1366 video, and successful
native screenshot responses that were also black. Therefore the later symptom
is not specific to TURN or the browser's rendered page.

At the time of the automated run, the physical display/lock state was not
confirmed. The operator subsequently confirmed that the display switched off
automatically and reported normal operation afterward. This supplies the missing
physical-state observation; it is not an independently measured capture or
power-assertion fix. Do not count black frames as visible-screen acceptance or
claim a proven reload regression from that run. Final candidate visual tests
must record the display state before and after reconnect. No private wake
selector, always-on assertion, timeout, VPN setting, or package was changed.

### Certificate Renewal and Post-Renewal Checks

The retained temporary managed `0.4.1` fixture passed a fresh wizard backup and
doctor before a controlled renewal. A qualification-only helper used the
installed Caddy `v2.11.4` dependency, CertMagic `v0.25.3`, and the existing ACME
account/storage to force one synchronous renewal. Only Caddy was stopped; an
independent timed restart guarded the maintenance window. Relay and coturn were
not restarted by the renewal helper. The helper was not added to the product.

The certificate changed, its expiration advanced, and Caddy served the new leaf
with normal hostname/trust verification after restart. This proves forced
renewal and subsequent serving, not observation of the long-term renewal timer.
Doctor passed ownership, managed files, secrets, Compose, services, local health,
and public routes afterward. Its external-TURN warning was checked separately:

- The coturn client sent and received 20/20 messages over each of UDP and TCP.
- Browser relay-only DataChannel echo passed for UDP/UDP, TCP/TCP, and mixed
  UDP/TCP paths. An initial same-transport run timed out despite connected ICE;
  a later mixed run delivered its echo but failed only the test's nominated-pair
  lookup. The harness now reads `transport.selectedCandidatePairId` first.
  Repeated same-transport and mixed runs passed without server, VPN, or product
  changes. The initial timeout's cause was not established; it is not evidence
  of a production fix or a substitute for final device reconnect acceptance.
- Trusted browser login and both `Pair device` / `Download package` paths
  returned version-matched packages with `201` and `no-store`; anonymous
  generation returned `401`. Unused qualification enrollments were revoked and
  removed, and the private downloaded packages were deleted.

This closes the engineering fixture's renewal gap. It does not populate a
schema-4 report for different final artifacts or qualify the NAT-host profile.

### Local 0.4.0 Preparation

`control` now uses `0.4.0`; the changelog entry does not imply publication.
`scripts/build-packages.sh --version 0.4.0` built both `iphoneos-arm` and
`iphoneos-arm64` public packages and audited each successfully. Build
orchestration tests and setup/personalization race tests passed. These local
packages were not installed or published, and their checksums are not a
replacement for the tag-bound draft's artifact provenance.

## Remaining Release Gates

1. Finish exact-candidate wizard/device acceptance. Fresh staged bootstrap,
   idempotence, trusted HTTPS/admin, package-generation UI, and browser TURN
   passed, as did exact-candidate backup/restore, admin reset, both uninstall
   recovery paths, and rootless updater/watchdog recovery. Complete managed
   upgrade/failure/interruption checks, renewal, and the physical-device
   package-install/enrollment path through the new host; engineering-fixture
   results do not qualify those final bytes.
   The RC4 browser/device TURN/TCP handshake fix and both-peer relay transport
   passed, and one unlocked session has visual screen/input proof. Repeat
   forced-relay media/control and reconnect checks with the exact candidate
   artifacts and a recorded physical display state. Resolve the newly observed
   packet-loss/decoder-stall failure before signing off those checks.
2. The tag-bound draft and independent file/image provenance checks are
   complete. Re-run the required release matrix for both package architectures,
   including package-manager upgrade/recovery and rootful transactional compatibility.
   The RC tests above cannot sign off different final artifact hashes.
3. Record only completed schema-4 qualification checks, then publish through
   the guarded release/APT workflows. Never use a personalized DEB as a public
   artifact or omit the installed-version rollback source from an update feed.

## Version Decision

The `v0.4.0` tag now identifies the draft candidate, not a published release. Rootless
support and the accumulated features justify a minor increase over `0.3.x`;
they do not by themselves establish the support guarantees of `1.0.0`. Keep the
wire protocol major unchanged unless an actual incompatible contract requires
a migration. Do not replace or retag existing release artifacts.

Local qualification DEBs use `0.4.0~rc.N` with exact package identity. The
GitHub draft workflow accepts `vMAJOR.MINOR.PATCH`
tags only; do not assume it already supports `v0.4.0-rc.N` tags.
