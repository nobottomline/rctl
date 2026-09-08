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
exact path in `packages/rootless/`. The version has a `~rootless3` prerelease
suffix. Objects and staging are isolated from the default rootful lane. The
package identifier remains `com.greatlove.rctl`, with `iphoneos-arm64`
architecture and dependencies on `ellekit` and `firmware (>= 15.0)`.

The script does not install, deploy, publish, or personalize the package.
The public APT feed remains rootful until device qualification is recorded.

Local verification on 2026-09-06: rootful and rootless packages both built and
passed `release_check.sh`; `make test` passed, including staging, relocated-path
protection, and rootless update rejection. The rootless Mach-O payloads have an
iOS 15.0 deployment target, the expected rootless rpaths, and the daemon's
existing media entitlements. Initial physical-device observations are recorded
below; runtime qualification is not complete.

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
   action. Inspect the installation output for errors. Installation resprings
   SpringBoard; do not interrupt it.
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

Signed transactional updates and personalized relay delivery are deliberately
unavailable in this test lane. An update request returns
`rootless_updates_not_qualified` instead of attempting to install a rootful
release. Upgrade/rollback qualification must precede enabling these features.

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

There is currently no REST action to change the device's interface orientation.
`GET /orient` is read-only, and the browser's rotate control changes only its
presentation. A device-orientation action is requested follow-up work: distinguish
it from rotation lock and viewer rotation, keep it SpringBoard-owned, and report
unsupported/failed requests explicitly. It must not serve as a workaround for
the capture-geometry defect.

## Diagnostics and Recovery

The existing logs remain `/tmp/rctld.log`, `/tmp/rctld.err.log`, and
`/tmp/rctld.out.log`. Crash reports remain under the system CrashReporter
directories. Review logs before sharing them; they may contain device metadata.

If SpringBoard cannot start normally, reboot and re-enable Dopamine with tweak
injection disabled, then remove `com.greatlove.rctl` using Sileo. Do not keep
retrying the same failing package or disable system protections to force it to
load. Keep the failed installation output and the relevant crash report.

The package does not hide camera or microphone privacy indicators. It also does
not remove personal files or relay identity when uninstalling its code.
