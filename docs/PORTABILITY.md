# Platform Portability

## Supported baseline

The release package is currently qualified only on iPad11,3, iOS 14.4, rootful
unc0ver and Substitute. It must not be advertised as rootless or iOS 15/16
compatible until the runtime matrix below passes on physical hardware.

The architecture is portable, but the package is not yet path-neutral. The
current rootful `.deb` uses `iphoneos-arm`, depends on `mobilesubstrate`, installs
code below `/Library` and `/usr/local`, and re-signs it from maintainer scripts.

## Build lanes

Keep one package identifier and produce separate artifacts:

| Lane | Package scheme | Minimum iOS | Package architecture | Qualified injector |
|---|---|---:|---|---|
| Rootful | default | 14.0 | `iphoneos-arm` | Substitute |
| Rootless | `THEOS_PACKAGE_SCHEME=rootless` | 15.0 | `iphoneos-arm64` | ElleKit |

Do not build both schemes in the same object tree without `make clean`. Rootless
v2 may use a relocated jailbreak root, so runtime code must use Theos/libroot
path helpers rather than hard-coding `/var/jb`.

## Path ownership

Paths fall into three groups and must not be prefixed indiscriminately:

| Ownership | Examples | Rootless rule |
|---|---|---|
| Package/injector | tweak dylibs, inactive audio payload, `rctld`, LaunchDaemon | resolve below the jailbreak root |
| Persistent user data | relay preferences, recordings, media cache | keep under `/var/mobile` |
| Ephemeral/system | `/tmp`, `/var/run`, `/var/mobile/Media`, Apple frameworks | keep in the root filesystem namespace |

Current rootless blockers found in the codebase:

- `layout/`, all native Makefiles and top-level staging assume rootful install
  destinations.
- `rctlapp` hard-codes the manually loaded `rctlappmedia.dylib` path.
- daemon audio activation hard-codes the inactive payload, injector directory,
  `ldid` and `killall` paths.
- `postinst`, `prerm`, `deploy.sh`, `audio.sh` and `release_check.sh` assume
  `/Library/MobileSubstrate` and rootful launchd locations.
- the LaunchDaemon embeds `/usr/local/bin/rctld` in `ProgramArguments`.
- injector detection partly understands `/var/jb`, but diagnostics and tweak
  counting still prefer rootful paths.
- package dependencies and the entitlement/signing flow have only been proven
  with Substitute/unc0ver.

The web client, relay preferences, media files, loopback ports and Unix sockets
are data/runtime state and should not move merely because the code package is
rootless.

## Private API policy

Every optional private UI hook must resolve its class and selector at runtime and
fail open. A missing hook may remove a cosmetic capability, but must not stop the
daemon, crash SpringBoard or break capture. Core paths such as screen capture,
touch injection, camera ownership, TCC behavior and audio session setup need an
explicit version adapter or a startup capability result; silently assuming the
iOS 14 ABI is not acceptable.

The green camera-dot hook follows this rule. The room-microphone filter also
matches SystemStatus attribution by daemon PID, so an API mismatch leaves the
orange dot visible and does not suppress another process's indicator.

## Qualification matrix

For each supported iOS/jailbreak pair, validate on a physical device:

1. Install, upgrade, remove, userspace reboot and jailbreak re-enable.
2. SpringBoard and foreground-app injection with no safe-mode or crash loop.
3. LAN control while relay configuration is absent, invalid and active.
4. Screen H.264, input sender ID, orientation and lock/unlock recovery.
5. Front/rear still and live camera, app roaming, recording and lease cleanup.
6. Playback Listen, room-microphone Listen/Record, Talk and audio-session recovery.
7. Privacy indicators: rctl-owned suppression, unrelated app visibility and
   fail-open behavior with each optional hook disabled.
8. Terminal, files, Photos, package/tweak inspection and path containment.
9. Public-package secret audit and personalized relay upgrade continuity.
10. Idle, memory, thermal and 30-minute media soak tests.

The first rootless target should be one known Dopamine device on iOS 15 or 16.
Only after that lane passes should CI publish a rootless `.deb` beside the
existing rootful artifact.

## References

- Theos rootless package scheme: <https://theos.dev/docs/rootless>
- Theos package architecture rules: <https://theos.dev/docs/packaging>
- libroot relocated-jailbreak path API: <https://github.com/opa334/libroot>
- Dopamine supported iOS/device families: <https://github.com/opa334/Dopamine>
- ElleKit Substrate-compatible hook API: <https://github.com/tealbathingsuit/ellekit>
