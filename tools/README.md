# Developer Tools

This directory contains small development and diagnostics utilities that are not
installed in the public package. Keep them non-secret, narrowly scoped, and safe
to run from a dirty worktree.

Production lifecycle behavior belongs in `scripts/`, `rctl-setup`, or the device
runtime rather than an undocumented tool.

- [tailnet-probe](tailnet-probe/README.md): isolated Tailscale runtime/HTTPS
  qualification and loopback TURN tests; no rctl API or production integration.
