#pragma once

#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Provision the device's local access identity at daemon start:
//  - the persistent LAN token (32 random bytes, hex-encoded) stored atomically
//    with mode 0600 outside the package payload; created on first start and
//    preserved across upgrades and rollbacks, never regenerated silently;
//  - a per-process relay-hop credential (32 random bytes, hex) kept only in
//    memory: rctld's own loopback consumers (RelayClient) present it so the
//    gateway can tell the authenticated relay tunnel apart from any other
//    loopback caller.
// Returns false when neither could be provisioned safely; the HTTP gateway
// then fails closed.
bool rctl_device_identity_provision(void);

// The 64-char lowercase hex LAN token, or NULL before provisioning.
const char *rctl_device_token(void);

// The 64-char lowercase hex relay-hop credential, or NULL before provisioning.
const char *rctl_relay_hop_credential(void);

// Constant-time comparisons. Only the exact full-length hex value matches;
// absent, short, or overlong presentations are rejected.
bool rctl_device_token_matches(const char *presented);
bool rctl_relay_hop_matches(const char *presented);

#ifdef __cplusplus
}
#endif
