# rctl

rctl lets people use their iPhone or iPad remotely, from a browser or a native
app. It supports local connections and a self-hosted relay for access away from
home. We aim for responsive control, predictable behavior, and clear ownership
of devices and data.

Changes should make the product easier to use and maintain without weakening
privacy, compatibility, or reliability. The sections below explain the
engineering boundaries that support those goals.

## What We Protect

- **Local control remains useful.** Installing, disabling, or losing a relay
  must not break LAN access. The exception is the administrator's explicitly
  approved, persisted `Relay only` policy.
- **Public packages stay public.** A public `.deb` contains no relay credentials
  or personalized configuration. Personalization derives from a clean public
  artifact; upgrades preserve the installed device's identity.
- **Capabilities belong to their processes.** Screen capture and input belong
  to SpringBoard, live camera and virtual-mic hooks to the foreground app, and
  playback-audio capture to `mediaserverd`. The daemon coordinates transport.
- **Idle means idle.** Viewer loss, lease expiry, process exit, and failed
  handoff release held input, capture sessions, encoders, recordings, and power
  assertions. Keep realtime queues bounded; do not fix latency by accumulating
  more work.
- **Compatibility needs evidence.** Preserve the rootful iOS 14 target and
  `arm64`/`arm64e`. Keep rootless paths and private-API availability explicit.
  A successful build on one lane does not qualify another device or jailbreak.

## Before Changing Code

Read `git status` and recent commits. Other engineers may be working in this
checkout. Re-read shared files before editing; do not reset, clean, revert, or
reformat unrelated work.

Read [ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing ownership or data
flow, then the relevant feature contract from the [docs index](docs/README.md).
Prefer the smallest complete change within those boundaries. Add an abstraction
only when an existing consumer or duplicated behavior justifies it.

## Where Code Lives

- `springboard/`: screen capture, input injection, and SpringBoard-only actions.
- `daemon/`: root HTTP/WebSocket server, IPC coordination, and WebRTC transport.
- `app/`, `app/media/`: foreground-app camera and virtual microphone hooks.
- `audio/`: opt-in playback capture inside `mediaserverd`.
- `core/`: native code shared by those processes, not a new runtime owner.
- `web/`: device control client for LAN and relay; `web/legacy/` is reference-only.
- `relay/`: Go relay and setup wizard; `relay/web-admin/` is a separate admin UI
  with its own build, not the device client.
- `mobile/`: independent native controllers, not payloads in the device `.deb`.
- `protocol/`: versioned contracts, fixtures, and generated constants, not a
  shared runtime. See its [generation rules](protocol/README.md).
- `layout/`, `updater/`: package payload/lifecycle and transactional device updates.

## Mistakes To Avoid

1. **Testing against live state.** Use disposable databases, profiles, and
   simulators. Do not point a test server at production state or copy real keys,
   enrollment tokens, personal media, or identifiers into fixtures. If a real
   dataset is necessary, obtain approval and sanitize an isolated snapshot.
2. **Trusting a transport.** HTTP, IPC, loopback ingest, DataChannels, package
   files, and relay state are trust boundaries. Validate identity, authorization,
   state, lengths, and paths. A UI capability flag is not server authorization.
3. **Treating all failures alike.** Unsupported optional private APIs should
   degrade without crashing. Failed authorization or package verification must
   fail closed, not silently enable a less protected path.
4. **Losing the recovery path.** Do not kill processes by name or reuse personal
   simulators for tests. Stop only test resources you created and tracked;
   service restarts need task authorization. On-device work can disconnect the
   controller you are using; establish recovery access before changing services
   or packages.

Never include secrets, private endpoints, personal identifiers, or production
data in source, logs, fixtures, docs, commits, or review evidence.

## Check Every Affected Path

Before calling a feature done, state which of these apply and what was tested:

- **Connections:** direct LAN, relay, reconnect, relay unavailable, and the
  explicit Relay-only policy. Browser secure-context restrictions still apply.
- **Clients:** device web UI, relay admin UI, and native controllers. Not every
  feature needs every client, but unsupported paths need an explicit decision.
- **Platforms:** rootful/rootless, iOS/private-API availability, package paths,
  and architecture. Do not infer support from a different working iPad.
- **Lifecycle:** start, stop, cancellation, lease expiry, backgrounding, and
  process/viewer loss. Include release of held keys and media resources.
- **Contracts:** both senders and receivers, capability negotiation, older
  peers, and generated fixtures. A protocol change is not a one-client edit.
- **Delivery:** fresh install, upgrade, identity preservation, and rollback
  when package or updater behavior changes.

## Verification

Use the [development guide](docs/DEVELOPMENT.md) for setup and commands. Start
with focused tests, then broaden for shared behavior, contracts, or packaging.
Do not run every toolchain for a docs-only change; do not use that shortcut for
a cross-component runtime change.

Tests should prove observable behavior, including failure and recovery, rather
than mirror implementation details. Compilation does not prove camera, audio,
input, lifecycle, or relay behavior. Exercise the real device/browser path when
needed and report anything not exercised. An untested path stays unqualified.

## Documentation

- `README.md` helps users choose and install the product. `CONTRIBUTING.md`
  explains contribution expectations. This file guides agents; the development
  guide owns setup and verification commands. Link instead of duplicating them.
- Internal docs explain decisions, cross-process constraints, compatibility,
  and traps that code alone does not make clear. Keep local implementation
  explanations near the code; avoid catalogs of functions or narrated diffs.
- Rewrite outdated guidance when behavior changes. Do not append a competing
  description beneath it or create a new page for every control or patch.
- Qualification records are different: retain version-scoped evidence and
  unresolved gates. Distinguish a local fix, a tested artifact, and a published
  release; do not turn a successful smoke test into a support claim.
- Keep temporary plans, raw logs, and PR-only screenshots outside tracked
  source. Sanitize evidence before sharing it. Do not erase existing planning
  or qualification documents as unrelated cleanup.

## Delivery

Owner-authorized work may use the current primary branch unless the task
requires another branch or worktree. External contributions use a fork and
topic branch; other maintainers also submit PRs. Follow the
[contribution workflow](CONTRIBUTING.md#fork-and-pull-request-workflow).
The owner's personal bypass is not permission to force-push or delete `main`.
Stage only task-owned files and commit coherent, verified work with
concise English Conventional Commit messages. Keep AI signatures and
`Co-authored-by` trailers out of commit messages. Do not commit generated build
artifacts or personalized packages.

For AI-assisted work, end the PR description with the model and harness used
(the app or CLI running the agent). List each model/harness pair that contributed;
if the exact model is unavailable, say so rather than guess. This disclosure
belongs in the PR body, not a commit message or attribution trailer. It does not
replace verification or the contributor's responsibility for the change.

Do not create PRs, push, publish, deploy to a VPS, or replace release artifacts
unless the user requests that step. The owner has granted standing permission
to deploy verified device-side changes to the configured test iPad unless they
opt out. Use `scripts/deploy.sh` with operator-configured `RCTL_SSH` for its
supported rootful lane, never `make package install`. For rootless, follow
[ROOTLESS.md](docs/ROOTLESS.md); do not bypass the deploy script's lane guard.
Do not hard-code device addresses or aliases.

End with what changed, what actually passed, and remaining limits. Follow the
[PR template](.github/pull_request_template.md) when a PR is requested.
