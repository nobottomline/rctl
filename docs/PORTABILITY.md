# Platform Portability

## Supported baseline

The release package is currently qualified only on iPad11,3, iOS 14.4, rootful
unc0ver and Substitute. It must not be advertised as rootless or iOS 15/16
compatible until the runtime matrix below passes on physical hardware.

An experimental rootless build lane is available for manual Dopamine testing.
It is not a qualified release. See [Rootless Testing](ROOTLESS.md) for the build,
installation, recovery, and result checklist. The rootful lane retains its
existing deployment target and installation paths.

## Build lanes

Keep one package identifier and produce separate artifacts:

| Lane | Package scheme | Minimum iOS | Package architecture | Qualified injector |
|---|---|---:|---|---|
| Rootful | default | 14.0 | `iphoneos-arm` | Substitute |
| Rootless | `THEOS_PACKAGE_SCHEME=rootless` | 15.0 | `iphoneos-arm64` | ElleKit |

`mk/native-target.mk` selects the target for every native subproject. Rootless
uses separate `.theos/obj/rootless*` objects, `.theos/_rootless` staging, and
`packages/rootless/` output. The rootful default output is unchanged. Never
override these directories to share objects between schemes.

Runtime package paths use Theos/libroot via `core/platform/Paths.h`. The Dopamine
package and maintainer scripts use the standard `/var/jb` installation alias;
runtime library resolution also supports libroot's relocated prefix. This does
not qualify other bootstrap variants such as RootHide.

## Path ownership

Paths fall into three groups and must not be prefixed indiscriminately:

| Ownership | Examples | Rootless rule |
|---|---|---|
| Package/injector | tweak dylibs, inactive audio payload, `rctld`, LaunchDaemon | resolve below the jailbreak root |
| Persistent user data | relay preferences, recordings, media cache | keep under `/var/mobile` |
| Ephemeral/system | `/tmp`, `/var/run`, `/var/mobile/Media`, Apple frameworks | keep in the root filesystem namespace |

The experimental lane now prefixes the loader's media library, playback-audio
payload and injection paths, package database access, package tools, shell, and
diagnostics. The daemon supplies the bootstrap's executable search path to its
children. File deletion protects the resolved jailbreak root and its ancestors.

`scripts/stage_package.py` finalizes rootless dependencies, launchd arguments,
and maintainer scripts before Theos prefixes the payload. Rootless executables
are signed at build time; installation and audio activation preserve those
signatures instead of applying the rootful on-device re-signing workaround.

The web client is a package asset: rootless installs it at
`/var/jb/usr/local/share/rctl/web/index.html`; rootful retains
`/var/mobile/rctl/index.html`. Relay identity, recordings, media caches, loopback
ports, and Unix sockets retain their existing locations.

Still unqualified or intentionally unavailable:

- Every physical-device runtime check below, including ElleKit loading and
  the existing private API behavior on iOS 15.5.
- Rootless transactional updates: the capability is omitted, the API returns
  `501 rootless_updates_not_qualified`, and the updater executable rejects use.
  The signed release catalog currently contains rootful artifacts.
- Rootless personalization, relay-wizard delivery, and automated recovery
  deployment. The existing personalization/deploy scripts reject this lane.
- `scripts/audio.sh` is a rootful operator helper, not the rootless test entry
  point. Exercise audio through the web control client.
- Publishing rootless artifacts to the APT feed or public releases.

## Private API policy

Every optional private UI hook must resolve its class and selector at runtime and
fail open. A missing hook may remove a cosmetic capability, but must not stop the
daemon, crash SpringBoard or break capture. Core paths such as screen capture,
touch injection, camera ownership, TCC behavior and audio session setup need an
explicit version adapter or a startup capability result; silently assuming the
iOS 14 ABI is not acceptable.

Camera and microphone privacy indicators are not hooked. They remain visible on
every supported iOS version whenever the corresponding sensor is active.

## Qualification matrix

For each supported iOS/jailbreak pair, validate on a physical device:

1. Install, upgrade, remove, userspace reboot and jailbreak re-enable.
2. SpringBoard and foreground-app injection with no safe-mode or crash loop.
3. LAN control while relay configuration is absent, invalid and active.
4. Screen H.264, input sender ID, orientation and lock/unlock recovery.
5. Front/rear still and live camera, app roaming, recording and lease cleanup.
6. Playback Listen, room-microphone Listen/Record, Talk and audio-session recovery.
7. Native privacy indicators for live/still camera and room-microphone capture.
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
