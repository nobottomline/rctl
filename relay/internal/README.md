# Relay Internals

These packages are private implementation boundaries:

- `relay/`: HTTP/WebSocket service, admin API, database, and tunnel brokers.
- `setup/`: owned-file manifests and transactional VPS lifecycle operations.
- `deb/`: inspection and personalization of a clean public package.
- `qualification/`: strict release-evidence schema and verifier.

Keep setup ownership separate from runtime state. Any filesystem, network,
database, package, or JSON input crossing these packages must be bounded and
validated.
