# Documentation

Start with [ARCHITECTURE.md](ARCHITECTURE.md) for process ownership and data
flow, then read the feature document for the code being changed.

- [SECURITY.md](SECURITY.md): trust boundaries, LAN/relay-only policy, and recovery.
- [SETUP.md](SETUP.md): VPS wizard, lifecycle operations, and recovery.
- [RELAY.md](RELAY.md): relay protocol, deployment profiles, and transport.
- [UPDATES.md](UPDATES.md): signed transactional device updates.
- [TRANSPORT.md](TRANSPORT.md): WebRTC/DataChannel architecture.
- [MOBILE.md](MOBILE.md): native iOS/Android controller architecture, authentication,
  media ownership, and delivery gates.
- [MOBILE-PLAN.md](MOBILE-PLAN.md): monorepo layout, implementation sequence,
  qualification gates, and mobile release boundaries.
- [MOBILE-DESIGN.md](MOBILE-DESIGN.md): native information architecture,
  interaction model, visual system, states, and accessibility gates.
- [MEDIA.md](MEDIA.md), [CAM.md](CAM.md), [AUDIO.md](AUDIO.md), and
  [VIRTUAL_MIC.md](VIRTUAL_MIC.md): media ownership and lifecycle.
- [TERMINAL.md](TERMINAL.md): terminal protocol and relay tunneling.
- [QUALIFICATION.md](QUALIFICATION.md): immutable release qualification.

Historical qualification records describe evidence for a specific release;
they are not substitutes for the current architecture and feature contracts.
