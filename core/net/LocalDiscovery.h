#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Call only after the LAN listener and all handlers are ready. Never for loopback.
void rctl_discovery_start(uint16_t port);
void rctl_discovery_stop(void);
const char *rctl_discovery_status(void);

#ifdef __cplusplus
}
#endif
