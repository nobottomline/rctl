#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Starts the optional internet relay control-plane client.
// No-op when /var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist
// is missing or disabled.
void rctl_relay_start(void);

#ifdef __cplusplus
}
#endif
