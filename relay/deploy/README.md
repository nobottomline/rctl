# Manual Relay Deployment Assets

This directory contains reference Compose, proxy, and TURN deployment files for
operators who do not use the managed wizard profile. The supported default is
`rctl-setup`; manual deployments own their lifecycle and upgrades.

Never copy example credentials into production. Pin images by digest, keep relay
port `8080` private, terminate TLS at the edge, and follow `docs/RELAY.md`.
