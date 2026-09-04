# Maintainer Scripts

Scripts here build, deploy, personalize, audit, qualify, and release rctl. Prefer
the documented wrapper over ad hoc package or server mutation.

`deploy.sh` is the supported device deployment path. `install.sh` is the small
public bootstrap for the Go VPS wizard. Release scripts must fail closed on
unexpected files, mutable identities, checksum differences, or missing
provenance. Never add credentials or personal endpoints to script defaults.

`publish_apt_release.sh` is the idempotent cross-repository ledger publisher
used only after an immutable release passes qualification and publication. Its
SSH deploy key must remain scoped to the public distribution repository.
