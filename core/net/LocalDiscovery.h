#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Call after the LAN listener is ready, before publishing policy-changing REST.
// Never call for a loopback-only listener.
void rctl_discovery_start(uint16_t port);
void rctl_discovery_stop(void);
const char *rctl_discovery_status(void);

#ifdef __cplusplus
}
#endif
