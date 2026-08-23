# Relay Commands

- `rctl-relay`: production relay service.
- `rctl-setup`: VPS preflight, install, upgrade, backup, restore, and recovery.
- `rctl-update-manifest`: creates a signed device-update catalog.
- `rctl-verify-qualification`: validates a privacy-safe release report.

Release binaries are built with version, commit, and digest-pinned image metadata
through `.github/workflows/release-draft.yml`. Do not embed secrets in ldflags or
command output.
