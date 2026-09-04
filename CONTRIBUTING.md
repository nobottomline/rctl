# Contributing to rctl

Thank you for improving rctl. Changes must preserve the project's security,
compatibility, and package-isolation boundaries.

## Before opening a change

1. Read `docs/ARCHITECTURE.md` and the feature document for the component.
2. Search existing issues and keep one change focused on one problem.
3. Never include credentials, private hostnames, device identifiers, personal
   media, relay databases, personalized packages, or production logs.
4. Preserve local LAN control when relay configuration is absent or unavailable.
5. Preserve iOS 14, `arm64`, and `arm64e` unless the change explicitly updates
   the documented compatibility contract.

Security vulnerabilities must not be reported in a public issue. Use
[GitHub private vulnerability reporting](https://github.com/nobottomline/rctl/security/advisories/new).

## Development

Run the narrowest relevant checks first, followed by the broader checks required
by the affected boundary:

```sh
make test
(cd web && npm ci && npm run build)
(cd relay && go test ./...)
(cd relay/web-admin && npm ci && npm run lint && npm run build)
make package FINALPACKAGE=0
make release-check
```

Native compilation alone does not qualify camera, audio, input, lifecycle, or
relay behavior. Describe the physical-device and browser paths that were
actually exercised, and state clearly what was not tested.

Use `scripts/deploy.sh` for physical-device deployment. Do not use `make package
install`, commit generated `.deb` files, or add personalized configuration to a
public artifact.

## Pull requests

- Explain the user-visible behavior and material engineering tradeoffs.
- Add focused tests for changed protocol, lifecycle, security, or parsing logic.
- Update durable documentation when behavior or an invariant changes.
- Keep generated sources synchronized and avoid unrelated formatting churn.
- Use concise English commit messages without generated attribution trailers.

By contributing, you agree that your contribution is licensed under the Apache
License 2.0 used by this repository.
