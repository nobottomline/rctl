#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Starts the optional internet relay control-plane client.
// No-op when /var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist
// is missing or disabled.
void rctl_relay_start(void);

// Malloc-owned JSON: configured/connected relay counts for updater verification.
char *rctl_relay_status_json(void);

// Counts-only variant for the credential-free legacy probe (no relay URLs).
char *rctl_relay_status_counts(void);

#ifdef __cplusplus
}
#endif
