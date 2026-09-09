# Debian Package Layout

Files below this directory are staged into the device package. It owns
launchd metadata, static runtime assets, the update public-key pin, and Debian
maintainer scripts.

`scripts/stage_package.py` excludes this README from the payload and adapts the
launchd plist and maintainer scripts for the experimental rootless lane before
Theos applies its package prefix. Rootful runtime paths remain unchanged.

The public package must contain no relay URL, enrollment token, device secret,
or private host data. Treat `DEBIAN/preinst`, `postinst`, and `prerm` as
recovery-critical code and verify changes with `make release-check`.
