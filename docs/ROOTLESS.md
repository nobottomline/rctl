# Rootless Device Testing

The rootless lane is experimental. Its first target is a user-owned iPad on
iPadOS 15.5 with ordinary Dopamine and ElleKit. Compilation and package audits
are not proof that the private APIs work on that device. RootHide and other
bootstrap variants are outside this first test lane.

## Build

Use the same native dependencies as the rootful build, plus the Theos iOS 15.6
SDK and current rootless support (including libroot). Configure `THEOS` to your
local installation, then run:

```sh
scripts/build-rootless.sh
```

The script builds all components, runs the public-package audit, and prints the
exact path in `packages/rootless/`. Default versions now use
`<control-version>~test.<UTC timestamp>.<Git revision>`; the historical
`~rootless14` suffix is no longer hard-coded. Objects and staging are isolated from the default rootful lane. The
package identifier remains `com.greatlove.rctl`, with `iphoneos-arm64`
architecture and dependencies on `ellekit` and `firmware (>= 15.0)`.

To build both lanes with the same version, use `scripts/build-packages.sh`.
For a release candidate with an exact Debian version, pass `--version 0.3.5`
(replace this example with the intended release version). Both lanes are built
sequentially because they share the web build and Theos aggregate metadata.
These scripts do not install, deploy, publish, or personalize the package.
The public APT feed remains rootful until device qualification is recorded.

Local verification on 2026-09-06: rootful and rootless packages both built and
passed `release_check.sh`; `make test` passed, including staging, relocated-path
protection, and rootless update rejection. The rootless Mach-O payloads have an
iOS 15.0 deployment target, the expected rootless rpaths, and the daemon's
existing media entitlements. Initial physical-device observations are recorded
below; runtime qualification is not complete.

Keyboard follow-up (2026-09-09/10): `rootless9` installed successfully and the
operator confirmed Minecraft control through the browser's new Game mode.
`rootless10` retains that native backend and adds stricter browser response
validation and separation from macro recording/playback. It is a local test
candidate, not a published APT release or completed Sileo upgrade qualification.
See [`KEYBOARD.md`](KEYBOARD.md) for evidence and the remaining input matrix.

`rootless13` adds opt-in virtual mouse capture over separate WebRTC control and
motion channels, replacing the initial stop-and-wait movement prototype.
`rootless14` adds explicit HID button transitions and separate control/motion
execution deadlines. These remain local qualification candidates.
See [`POINTER.md`](POINTER.md) for the separate mouse qualification record.

Media follow-up (2026-09-11): a daemon-only hotfix over `rootless14` resolved
video posters using bounded, read-only Photos derivatives. The full local video
index passed HTTP thumbnail decoding, and the browser's 60 initial video tiles
loaded successfully. This did not reinstall the package or change its dpkg
version. See [`MEDIA.md`](MEDIA.md) for implementation, evidence and limitations.

## First Install

1. Keep physical access to the iPad. Record its model, iOS version, Dopamine
   version, and ElleKit version. If a terminal is already available,
   `dpkg --print-architecture` should report `iphoneos-arm64`.
2. In Sileo, confirm that **ElleKit** (package identifier `ellekit`) is installed.
   A working package manager or Filza installation does not establish that
   tweak injection is installed. If missing, refresh the official source
   <https://ellekit.space/> (add it if absent), install ElleKit, and follow the
   package manager's restart instructions. Filza's `dpkg -i` installation does
   not download dependencies automatically.
3. Transfer the exact test `.deb` to the iPad using AirDrop or another local
   file-transfer method. Open it in Filza and use its package installation
   action. Inspect the installation output for errors. After dpkg has exited,
   use the package manager's Restart SpringBoard action. A direct terminal
   installation prints a reminder instead; run `sudo sbreload` only after the
   installation command has completed. Do not interrupt dpkg with a respring.
4. On a trusted Wi-Fi network, open `http://<ipad-ip>:8080/` in a browser. Local
   access has the same unauthenticated trusted-LAN policy as the rootful build.
5. Test screen display, orientation, taps, typing, and Home first. Then proceed
   with media and the remaining functions below.

Do not force an architecture mismatch, rename a rootful package's architecture,
or use the rootful `scripts/deploy.sh`/`scripts/audio.sh` helpers on this device.
No relay configuration is required for this first LAN test.

### Missing ElleKit After Unpacking

`depends on ellekit; however: Package ellekit is not installed` means dpkg
unpacked rctl but left it unconfigured. Its `postinst` was not run. Install
ElleKit from the official source, then retry the same rctl file in Filza to
complete configuration. Do not use `--force-depends` or remove the dependency.
The official [ElleKit package index](https://ellekit.space/Packages) lists
`ellekit` for `iphoneos-arm64`; the dependency name is intentional.

If Sileo's **Open in Sileo** route instead reports `Unsupported file` for a path
under `/var/jb/var/cache/apt/archives/`, local-file import failed separately from
dependency configuration. The message alone does not establish a corrupt deb
or its exact filesystem cause. Use Sileo for the ElleKit dependency, then
Filza for the already downloaded rctl test package. The rootful public feed
does not contain this rootless prerelease, so refreshing that feed cannot make
Sileo download it.

## Test Record

Record pass/fail and the concrete symptom for each item. For media failures,
record the foreground app and whether another audio/camera session was active.

| Area | Checks | Initial status |
| --- | --- | --- |
| Installation | Install output; daemon launch; ElleKit injection; respring | User completed installation; LAN API and SpringBoard screenshot path respond |
| Screen/input | Video; taps; swipe; keyboard; buttons; orientation | rootless2: WebRTC, four orientations, PNG and selected app/tab taps verified; full input matrix pending |
| Lifecycle | Lock/unlock; app switch; Home; browser disconnect/reconnect | Not tested |
| Still camera | Front/rear with a foreground app; native camera indicator | Not tested |
| Live camera | Front/rear; rotation; recording/download; stop/disconnect cleanup | Not tested |
| Audio | Playback Listen; room mic; Talk; recording; native mic indicator; stop cleanup | Not tested |
| Files/media | Browse; download; Photos; confirmed deletion and protected paths | Not tested |
| Terminal/packages | PTY; shell PATH; package list; tweak list and diagnostics | Not tested |
| Recovery | Remove; reinstall; jailbreak re-enable; no crash loop | Not tested |
| Soak | 30-minute stream; idle cleanup; memory/thermal behavior | Not tested |

Personalized packages can now be generated from either public architecture.
The rootless code remains below `/var/jb`; enrollment and persistent relay
identity remain at `/var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist`.
Use `scripts/personalize_deb.sh PATH_TO_ROOTLESS_DEB` or
`make THEOS_PACKAGE_SCHEME=rootless package-relay`. These are private artifacts,
not public APT packages. The base must have the matching runtime layout and
must not already contain relay configuration.

The relay has an independent optional `RCTL_RELAY_ROOTLESS_PACKAGE` path and
advertises only loaded package variants in Pair device. The existing
`RCTL_RELAY_PUBLIC_PACKAGE` remains rootful. Physical enrollment and a limited
remote smoke test are recorded below; they do not qualify the full remote
feature matrix or transactional updates.

Signed transactional updates remain unavailable in this test lane. A request returns
`rootless_updates_not_qualified` instead of attempting to install a rootful
release. Upgrade/rollback qualification must precede enabling these features.

### Package Preparation Qualification (2026-09-11)

- The common builder produced both Debian architectures with one automatic
  prerelease version; both real packages passed `release_check.sh`.
- Go personalization and independent `dpkg-deb` inspection passed for both
  real artifacts. Shell tests cover rootless identity placement, private modes,
  rejection of personalized bases, and mismatched architecture/layout.
- Build-orchestration tests cover both lanes, explicit version propagation,
  invalid inputs, rejected metadata mismatches, and default version ordering:
  newer than the historical `~rootless14` candidate, older than `0.3.4`.
- An isolated local relay loaded both real artifacts. Chrome UI tests selected
  Rootless in Pair device and downloaded it at 1280px, then selected Rootful and
  downloaded it at 390px. Independent inspection of both downloaded DEBs
  confirmed the requested Debian architecture. No production identity was used.
- `make test`, all relay Go tests, focused relay/deb race tests, and admin
  TypeScript/lint checks passed. The UI changes also remain compatible with
  a rootful-only relay status response.

These checks do not establish a physical install, approval/enrollment, remote
media/input, relay restart recovery, or transactional update/rollback. Public APT
publication and release-wizard integration remain gated on those separate paths.

### Physical Candidate Upgrade (2026-09-11)

The operator installed the public candidate generated by the common builder over
`0.3.4~rootless14` and restarted SpringBoard. Independent SSH checks confirmed
`0.3.4~test.20260911144246.9401c77dc934`, `install ok installed`, and new daemon
and SpringBoard process start times. No recovery configuration command was needed.
The earlier DEB and a copy of the pre-update daemon were retained on-device;
automatic rollback was not exercised.

The local capabilities, device-info (SpringBoard IPC), and orientation endpoints
all returned HTTP 200. Through an SSH-forwarded local HTTP endpoint, two new
Chrome WebRTC sessions decoded 1024x1366 frames with growing counters
(169 to 498, then 171 to 650) and no page exceptions. The second session opened
Media and Videos through the actual buttons: all 60 initial thumbnail images
decoded successfully. Both browser sessions were closed after verification.

This qualifies this particular public candidate upgrade and local video/media
smoke test. It is not evidence of a Sileo repository upgrade, clean install,
full input/audio/camera regression, remote relay enrollment, or signed update
and rollback. Those acceptance gates remain open.

### Existing Relay Enrollment (2026-09-11)

An existing self-hosted relay already contained the architecture-aware package
implementation but had no public base configured. Its binary was left unchanged.
The physically tested rootless public DEB was added through an isolated systemd
drop-in, with binary/configuration/database backups and a timed configuration
rollback. The initial attempt exposed a directory-permission error for the
unprivileged service account and rolled back. The corrected public directory
was checked for readability as the service user before repeating the restart.

Trusted external HTTPS, the rootless architecture/version in admin status, and
the previous approved device's identity, online state, and authenticated
capabilities tunnel passed before the configuration was accepted. This is a
configuration-change recovery test, not a signed device-update rollback test.

The actual admin UI then generated and downloaded an `iphoneos-arm64` package
for a new device with a one-hour enrollment. Independent extraction verified the
unchanged package version, rootless daemon path, unprefixed mode-`0600` relay
configuration, canonical WSS endpoint, and enabled local access. The private DEB
was transferred over SSH to the target with matching SHA-256.

The operator installed this package over the public candidate using Filza,
restarted SpringBoard, and unlocked the device. Independent SSH checks confirmed
the expected version with `install ok installed` and a root-owned mode-`0600`
configuration. The new pending record was matched to the issued package's
enrollment using the relay's actual token fingerprint algorithm and a read-only
database query, not its display name. The admin UI's **Approve device** action
and **Open control** row were then exercised in Chrome.

- Remote WebRTC decoded frames advanced from 172 to 748 in ten seconds at
  1024 x 1366; no browser page errors were observed.
- **Media > Videos** loaded all 60 video posters through the remote UI.
- An authenticated read of the persisted device configuration confirmed the
  same DeviceID, a stored device secret, removal of the one-time enrollment
  token, and enabled local access. No secret values were printed or committed.
- An independent local browser session after enrollment advanced from 171 to
  632 decoded frames in eight seconds and loaded all 60 video posters.
- Both the previous rootful device and the new rootless device remained approved
  and online. The relay, TLS proxy, coturn, and existing AMP services were active.

### Forced TURN Qualification (2026-09-11)

Opening control through the relay domain alone does not establish WAN media
coverage: the normal test selected a direct ICE path. The browser test therefore
forced `iceTransportPolicy: 'relay'` both in the peer constructor and in later
`setConfiguration` calls. Applying it only at construction was insufficient
because the client subsequently installs the supplied ICE servers. Selected
candidate-pair statistics independently confirmed a local `relay` candidate
and a remote `srflx` candidate.

The ordinary profile was not consistently usable on this route. One ten-second
sample advanced only 26 to 33 decoded frames. Another advanced 19 to 108, while
received packets increased by 2,902 and reported lost packets by 2,326, with
heavy NACK/PLI activity. A connected ICE state and occasional decoded frames
must not count as a performance pass.

Choosing **Saver** through the UI improved the short test: 62 to 245 decoded
frames in ten seconds at 818 x 1092, with no reported packet loss in that
interval. Selected-pair RTT was approximately 862 ms. The TURN shared secret
matched the relay configuration; no explicit `max-bps` or `bps-capacity` setting
was present. These observations establish route/profile sensitivity, not the
cause of the network loss or a rootless-specific defect. Automatic bitrate
adaptation and real separate-network/Safari coverage remain unqualified.

The subsequent minute-long Saver test did **not** pass. An initial attempt
selected Saver before connection and later observed 1024 x 1366 instead of its
expected resolution; this cannot qualify that profile. The repeat selected
Saver after connection and required 818 x 1092 before measuring. It advanced
62 to 540 decoded frames in 60 seconds (about 8 fps), reported 1,163 lost packets
after starting at zero, and increased PLI count from 7 to 102. No nominated
candidate pair was available at the final verification sample. Thus even the
lower profile is not a demonstrated stable solution on this route. Investigate
network loss/RTT, route changes, and RTP delivery before accepting WAN streaming;
do not treat the short successful interval as a completed soak test.

A final read-only route lookup showed that the test Mac reaches the relay host
through a tunnel interface. Its VPN/routing state was not changed. This is an
environmental confounder, not proof of the loss cause or of the exact media
route. Repeat on a known direct route before attributing the result to rootless
or changing transport constants. The test admin session was signed out afterward.

This enrollment smoke test does not cover every input, audio, camera, terminal,
revocation, process/network recovery, or signed upgrade/rollback scenario.
Do not enable the rootless updater or publish a fully qualified release on its
basis. The device still has its previous public DEBs available for recovery.

### Screen Geometry Failure (2026-09-07)

Observed with `0.3.4~rootless1`, iPadOS 15.5 and ElleKit 1.2 on an iPad Pro:

- A direct `/v1/screenshot` response is 2048x2732. Its lower portion is black,
  and part of the display is clipped before the browser processes the PNG.
- In landscape, `/orient` returns `3`. After the operator physically rotates
  the device to portrait, it returns `1`; orientation observation is working
  for this transition.
- In portrait, the raw PNG still contains sideways content and the same black
  lower region. This rules out browser rotation alone and demonstrates a
  mismatch between capture coordinates and UIKit portrait coordinates.
- The browser applies its normal interface-orientation rotation to those
  already incorrect pixels, explaining the sideways downloaded screenshot.

The old `core/capture/ScreenCapture.mm` sized the render surface from
`UIScreen.nativeBounds` and passed it directly to `CARenderServerRenderDisplay`.
The wrong assumption was that these APIs use the same portrait-native geometry.
A read-only on-device CADisplay probe confirmed the mismatch independently of
the interface orientation:

| Property | Value |
| --- | --- |
| UIScreen.nativeBounds | 2048x2732 |
| UIScreen.fixedCoordinateSpace.bounds | 1024x1366 points |
| CADisplay.bounds / frame | 2732x2048 pixels |
| CADisplay.nativeOrientation | rot270 |

This is a panel-coordinate issue, not a screen-diagonal threshold, a rootless
filesystem issue, or an incorrect orientation notification. Never hard-code
the correction by model, diagonal or iOS version.

`rootless2` reads geometry from the same main CADisplay it renders. A
capture-owned native surface preserves the entire panel; for nonzero panel
offsets, Accelerate/vImage losslessly normalizes BGRA pixels into a second
surface in UIKit's fixed coordinate system. Both the encoder and PNG writer
consume that canonical surface. The browser orientation protocol and touch
coordinates are unchanged. Zero-offset displays retain the direct-surface path
without the extra allocation or copy. Surfaces are released with their capture
context; a failed normalization drops the frame rather than encoding stale data.

Private geometry access is guarded. Unavailable metadata keeps the previous
UIKit-only fallback; present but inconsistent dimensions/unknown rotation values
fail capture setup with a diagnostic instead of guessing or crashing SpringBoard.
A CSS rotation, changing `/orient`, or cropping black pixels cannot recover
pixels already clipped by the undersized render surface.

Verification on the new device: clean remove/install under a crash/timeout
watchdog, full raw portrait PNG, browser `Save frame` landscape PNG (2732x2048),
WebRTC orientation transitions through 1/4/3/2 in one session without reloading,
opening Sileo by tapping its icon, and selecting bottom tabs in landscape and
upside-down portrait. A sample after roughly 695 seconds showed 20,850 video
frames, consistent with 30 fps; this is not a complete memory/thermal soak test.
The host suite tests all four pixel rotations, padded row strides, channel/alpha
preservation, geometry validation and the original 1668x2224 zero-offset case.
Both rootful (iOS 14, arm64/arm64e) and rootless packages build and pass public
package audits. The old device's configured SSH tunnel was unavailable, so
physical rootful regression and the full corner/input matrix remain pending.

`GET /orient` is read-only, and the browser's rotate control changes only its
presentation. The subsequently added `/v1/orientation` action is a separate,
SpringBoard-owned device control. It is not a workaround for the capture-geometry
defect and must remain distinct from viewer rotation.

## Diagnostics and Recovery

### Sileo Upgrade Qualification (2026-09-08 / 2026-09-09)

A real Sileo 2.5.1 upgrade on iPadOS 15.5 / Dopamine / ElleKit 1.2 exposed a
package lifecycle defect that a successful build and `apt-get update` did not:

1. A temporary, signed LAN APT source offered `0.3.4~rootless4` over the
   installed `0.3.4~rootless3`. Sileo displayed the correct candidate, queued
   only rctl, and downloaded the DEB through its normal repository path.
2. After confirming the transaction, Sileo exited, dpkg/APT were no longer
   running, the package remained `install ok half-configured`, and the daemon
   was absent. SpringBoard remained bootable.
3. An independent SSH session completed `sudo dpkg --configure
   com.greatlove.rctl`. Package status returned to `install ok installed` and
   the LAN API recovered. No new SpringBoard crash report appeared during this
   run. This is recovery evidence, not a successful Sileo upgrade.

Both old maintainer scripts forcibly killed SpringBoard during the transaction.
The rootless scripts now request `finish:restart` through the package manager's
`CYDIA` descriptor instead. Sileo implements this protocol and supplies `CYDIA`
alongside `SILEO`; its finish action runs after the transaction. Without a valid
open descriptor, the scripts print a manual respring instruction and never
restart the rootless GUI themselves. Rootful behavior is unchanged. References:
[APTWrapper](https://github.com/Sileo/Sileo/blob/main/Sileo/Backend/APT%20Wrapper/APTWrapper.swift),
[RootHelper](https://github.com/Sileo/Sileo/blob/main/SileoRootDaemon/RootHelper.swift).

The correction was installed as `rootless5` through SSH, followed by an explicit
`sbreload` after dpkg exited. `rootless6` was the matching next-version candidate
for the repeat Sileo upgrade. Host tests exercise the real restart functions
under both macOS sh and Linux dash: valid, absent, malformed, and closed finish
descriptors, plus the unchanged rootful restart branch.

On 2026-09-09, the operator completed the `rootless5` to `rootless6` update in
Sileo from the temporary signed LAN source and reported restarting SpringBoard.
Subsequent independent checks confirmed:

- dpkg reported `0.3.4~rootless6 install ok installed` without a recovery
  configuration command after this transaction.
- Both rctld and SpringBoard were running, and the LAN capabilities API responded.
- A newly opened control client received video at 1432 x 1912 pixels; its
  decoded-frame counter advanced from 352 to 687 over approximately 12 seconds.

This validates the corrected upgrade transition and post-restart LAN video
recovery. The Sileo completion interaction was operator-reported, not recorded
by browser automation. **Clean Sileo installation and a complete input/media
regression pass remain pending.** It does not qualify upgrades from the older
unsafe maintainer scripts described below.

The installed *old* `prerm` runs before a new package can replace it. Therefore
an upgrade from `rootless1` through `rootless4` can still encounter the old
respring behavior. Keep SSH and the previous DEB available. If no package
transaction remains active and rctl is half-configured, finish configuration
with the command above; do not delete dpkg locks, force dependencies, or reboot
mid-transaction. For the initial migration, install the corrected package from
an independent SSH terminal, then restart SpringBoard after completion.

The temporary source also confirmed that Sileo requires a `Components` field
in a flat repository's `Release`; architecture matching alone is insufficient.
The public repository generator already emits that field. A rootless DEB must
be admitted separately with actual `iphoneos-arm64` metadata and qualification;
do not advertise that architecture while serving only the rootful package.

No public release, relay deployment, or old-device update is qualified by this
local test. The full-release workflow remains gated by its relay/VPS checks.
A separately scoped LAN-only release path must retain artifact provenance,
checksums, and physical install/upgrade/recovery gates rather than marking
unperformed relay checks as passed.

### Runtime Diagnostics

The existing logs remain `/tmp/rctld.log`, `/tmp/rctld.err.log`, and
`/tmp/rctld.out.log`. Crash reports remain under the system CrashReporter
directories. Review logs before sharing them; they may contain device metadata.

If SpringBoard cannot start normally, reboot and re-enable Dopamine with tweak
injection disabled, then remove `com.greatlove.rctl` using Sileo. Do not keep
retrying the same failing package or disable system protections to force it to
load. Keep the failed installation output and the relevant crash report.

The package does not hide camera or microphone privacy indicators. It also does
not remove personal files or relay identity when uninstalling its code.
