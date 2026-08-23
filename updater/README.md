# Transactional Device Updater

`rctl-updater` is an external executable so package replacement never depends on
the daemon being replaced. It verifies the pinned-key catalog, downloads and
checks target plus rollback packages, preserves relay identity, performs a clean
remove/install, verifies daemon and SpringBoard recovery, and rolls back.

Do not convert this to upgrade-in-place or move it into `rctld`. The protocol and
release procedure are documented in `docs/UPDATES.md`.
