# Contributing to rctl

rctl exposes root-level device control. Small, reproducible fixes are easier to
review and qualify than broad rewrites. Start with one problem and explain why
the change belongs in the project.

## Start Here

- [Development guide](docs/DEVELOPMENT.md): prerequisites, builds, and checks.
- [Architecture](docs/ARCHITECTURE.md): process ownership and data flow.
- [Documentation index](docs/README.md): the contract for the affected feature.
- [Security policy](SECURITY.md): private vulnerability reporting.

You do not need a jailbroken device or a VPS for every contribution. Web,
protocol, and many relay changes can be tested locally. Be explicit when a
change still needs physical-device qualification.

## Propose One Change

Search existing issues before starting. For a new feature, ownership change,
protocol break, or large rewrite, discuss the problem and scope with maintainers
before implementing it. A focused bug fix should include the reproduction and
expected behavior; it does not need an architecture proposal.

Keep unrelated fixes and formatting out of the change. Dependency updates also
need evidence: a green build is not proof that audio still plays or a release
workflow still publishes correct artifacts.

## Protect Users

- Preserve LAN access when a relay is absent or unavailable, except for the
  administrator's explicitly selected Relay-only policy.
- Keep public packages free of personalized relay configuration and credentials.
- Preserve the documented platform targets and process ownership. A rootless
  build does not establish support for every rootless jailbreak.
- Do not test on devices, accounts, or infrastructure without permission.
- Never attach real tokens, signing keys, private endpoints, device identifiers,
  personal media, relay databases, or unsanitized logs.

Report suspected vulnerabilities privately through [SECURITY.md](SECURITY.md),
not a public issue. Participation follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Make Review Possible

Explain the problem, the fix, and any material tradeoff. Use the
[PR template](.github/pull_request_template.md) to record:

- Exact tests and commands run, with their results.
- Relevant connection modes and device/jailbreak combinations exercised.
- Known gaps, unsupported paths, and any remaining qualification gates.
- Sanitized before/after images for visible UI changes; a short recording when
  timing or interaction is the behavior under review.

Add focused tests for changed parsing, authorization, protocol, and lifecycle
behavior. Keep generated protocol sources synchronized. Follow the
[documentation rules](AGENTS.md#documentation): update guidance made inaccurate
by the change, not a second narrative of the implementation.

Use concise English Conventional Commit messages without AI signatures or
`Co-authored-by` trailers. Do not commit generated packages or PR-only evidence.
Publishing and deployment are separate maintainer operations, not consequences
of a successful local build.

## AI-Assisted Contributions

If you used an AI agent, end the PR description with the model and harness used.
The harness is the application or CLI running the agent, such as Codex or Claude
Code. List each model/harness pair that contributed. If the exact model is not
available, write `unknown`; do not infer it from the harness name.

Keep this disclosure in the PR body, not in commit messages or `Co-authored-by`
trailers. You remain responsible for reviewing the changes, running appropriate
checks, and explaining the result. If no AI agent was used, state `None` in the
template's AI assistance section.

By contributing, you agree that your contribution is licensed under the
[Apache License 2.0](LICENSE) used by this repository.
