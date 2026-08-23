#pragma once

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Local browser/API access is enabled unless the relay configuration explicitly
// opts into loopback-only operation. This preserves existing and public builds.
bool rctl_local_access_enabled(void);

// Disabling LAN access requires at least one approved relay identity so a
// remote-only device cannot be locked out by an incomplete enrollment.
bool rctl_local_access_set_enabled(bool enabled, char *error, size_t error_len);

// Relay approval and policy changes update the same atomic plist. Serialize
// read-modify-write transactions so neither operation can lose the other.
void rctl_relay_config_lock(void);
void rctl_relay_config_unlock(void);

#ifdef __cplusplus
}
#endif
