# Repository Agent Guide

This file is the operational entry point for coding agents. Keep it short and
keep durable product and protocol details in `docs/`.

## Start Here

- Read `docs/ARCHITECTURE.md` before changing runtime ownership or data flow.
- Read the feature document relevant to the change, especially `docs/RELAY.md`,
  `docs/CAM.md`, `docs/MEDIA.md`, `docs/TERMINAL.md`, or
  `docs/VIRTUAL_MIC.md`.
- Inspect `git status` and recent commits before editing. Other work may be in
  progress in the same worktree.

The main ownership boundaries are:

- `springboard/`: screen capture, input injection, and SpringBoard-only actions.
- `daemon/`: root HTTP/WebSocket server, IPC coordination, and WebRTC transport.
- `app/` and `app/media/`: foreground-app camera and virtual microphone hooks.
- `audio/`: opt-in playback-audio capture inside `mediaserverd`.
- `core/`: shared native implementation used by the runtime components.
- `web/`: device control client; `web/legacy/` is reference-only.
- `relay/`: Go relay and its separate admin client in `relay/web-admin/`.
- `mobile/`: independent native iOS and Android controller products.
- `protocol/`: versioned cross-client contracts, fixtures, and deterministic
  generated constants; it is not a shared runtime.
- `layout/`: package-owned static files and maintainer scripts.

## Product Invariants

- Local LAN control must continue to work when relay configuration is installed,
  unreachable, or disabled unless the administrator explicitly selected the
  persisted `Relay only` policy after approval.
- The public `.deb` must never contain relay credentials or personalized
  configuration. Personalized packages are derived from a clean public artifact.
- Preserve the established process ownership above. In particular, live camera
  capture belongs to the foreground app, screen capture to SpringBoard, and
  playback-audio capture to `mediaserverd`.
- Media features are idle by default. Viewer loss, lease expiry, process exit,
  and failed handoff must release capture sessions, encoders, recordings, and
  power assertions.
- Preserve iOS 14 support and both `arm64` and `arm64e`; do not assume APIs from a
  newer deployment target.
- Treat HTTP, IPC, loopback ingest, DataChannel messages, package files, and
  relay state as compatibility and security boundaries. Validate sizes, state,
  paths, identities, and authorization at those boundaries.
- Never put secrets, enrollment tokens, device secrets, private hostnames,
  personal identifiers, or production data in source, fixtures, logs, docs, or
  commits.

## Working Safely

- Preserve unrelated and concurrent changes. Do not reset, clean, revert, or
  reformat files outside the task.
- Re-read shared files before editing and stage only task-owned paths.
- Prefer the smallest complete change that uses existing component boundaries
  and helpers. Record material architectural decisions in the relevant document.
- Do not push, publish, deploy to a VPS, or replace a release artifact unless
  the user explicitly requests that delivery step. The user has granted
  standing authorization to deploy verified device-side changes to the
  configured target iPad unless they explicitly opt out; use
  `scripts/deploy.sh` with the operator-configured `RCTL_SSH`, and never
  hard-code device addresses or aliases.
- Device compilation is not runtime proof. Camera, audio, input, process
  lifecycle, and relay behavior require validation of the real execution path.

## Verification

Run the narrowest relevant checks first, then broaden based on blast radius:

- Native host tests: `make test`
- Device package: `make package FINALPACKAGE=0`
- Control client: `(cd web && npm run build)`
- Relay: `(cd relay && go test ./...)`
- Relay admin client: `(cd relay/web-admin && npm run lint && npm run build)`
- Relay smoke test: `./scripts/smoke_relay.sh`
- Public package audit: `make release-check`

Deploy verified device-side changes by default with `scripts/deploy.sh` and the
operator-configured target unless the user explicitly says not to deploy; do
not use `make package install`. Follow the feature document for physical-device
and browser validation. Report what was not exercised.

## Commits

- Work on the current primary branch unless the task requires another branch.
- Commit coherent, verified work with concise Conventional Commit messages.
- Do not add AI branding or `Co-authored-by` trailers.
- Keep generated artifacts, personalized packages, credentials, and unrelated
  work out of commits.
