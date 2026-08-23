# Debian Package Layout

Files below this directory are copied verbatim into the device package. It owns
launchd metadata, static runtime assets, the update public-key pin, and Debian
maintainer scripts.

The public package must contain no relay URL, enrollment token, device secret,
or private host data. Treat `DEBIAN/preinst`, `postinst`, and `prerm` as
recovery-critical code and verify changes with `make release-check`.
