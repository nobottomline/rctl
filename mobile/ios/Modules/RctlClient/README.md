# RctlClient

Native iOS controller identity and authenticated relay HTTP client.

The package validates short-lived QR payloads, owns P-256 signing keys in Secure
Enclave/Keychain, creates Go-compatible pairing and request proofs, and stores
only the refresh credential. Access tokens belong to the in-memory application
session coordinator.

Run unit and Keychain tests through `make mobile-ios-test`. For a local live Go
relay interoperability pass, provide `RCTL_CONTROLLER_TEST_ORIGIN` and
`RCTL_CONTROLLER_TEST_ADMIN_SECRET` to `swift test`; the test creates and revokes
its own controller. Insecure HTTP is accepted only for an explicitly enabled
loopback test origin.
