#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    RCTL_TALK_SPEAKER = 0,
    RCTL_TALK_VIRTUAL_MIC = 1,
    RCTL_TALK_BOTH = 2,
};

// Loopback-only PCM fanout for the injected foreground-app mic shim.
int rctl_vmic_server_start(void);
void rctl_vmic_push(const int16_t *pcm, int frames);
void rctl_vmic_set_route(int route);
int rctl_vmic_route(void);

#ifdef __cplusplus
}
#endif
