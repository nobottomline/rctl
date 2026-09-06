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
exact path in `packages/rootless/`. The version has a `~rootless1` prerelease
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
| Screen/input | Video; taps; swipe; keyboard; buttons; orientation | Capture geometry fails; some console actions work (user report); input matrix pending |
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

`core/capture/ScreenCapture.mm` sizes the render surface from
`UIScreen.nativeBounds` and passes it directly to
`CARenderServerRenderDisplay`. That assumes the render server uses the same
portrait-native geometry. The evidence is consistent with a landscape-native
panel coordinate system on this device, not with an incorrect orientation
notification. The exact display geometry/rotation API still needs on-device
validation; do not infer a universal offset from the iOS version or rootless
packaging scheme.

The repair should obtain the renderer's full geometry, then normalize captured
pixels to the existing canonical coordinate system before encoding or exporting
PNG. Keep screen rendering, screenshots and touch mapping consistent. A CSS
rotation, changing `/orient`, or cropping black pixels cannot recover pixels
already clipped by the undersized render surface. Qualify all four orientations,
in-session rotation and corner taps on both this device and the original
rootful lane before calling it fixed. No capture fix has been installed yet.

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
