# Security Policy

rctl exposes root-level device capabilities. Treat suspected authentication,
authorization, transport, package, path-containment, or secret-handling defects
as security issues.

## Supported versions

Security fixes are provided for the latest published stable release. Older
releases and unqualified development builds may be used to reproduce a problem,
but are not maintained as separate security branches.

The currently qualified device platform is documented in
[`docs/PORTABILITY.md`](docs/PORTABILITY.md). A platform not listed as qualified
must not be assumed to have the same security behavior.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/nobottomline/rctl/security/advisories/new).
Do not open a public issue for a suspected vulnerability.

Include the affected version, installation profile, impact, prerequisites, and
minimal reproduction steps. Before submitting, remove device identifiers,
personal media, hostnames, IP addresses, cookies, tokens, keys, relay databases,
and personalized `.deb` files.

Do not access devices, accounts, or infrastructure you do not own or have
explicit permission to test. Do not make production data unavailable while
investigating a report.

The architecture-level security model, trust boundaries, rate limits, relay
policy, destructive-action controls, and recovery behavior are maintained in
[`docs/SECURITY.md`](docs/SECURITY.md).
