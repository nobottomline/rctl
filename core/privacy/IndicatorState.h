#ifndef RCTL_PRIVACY_INDICATOR_STATE_H
#define RCTL_PRIVACY_INDICATOR_STATE_H

#include <stdbool.h>
#include <stdint.h>

#define RCTL_MIC_INDICATOR_NOTIFICATION "com.greatlove.rctl.mic-indicator-state"

// notifyd stores one 64-bit value per notification name. Bit zero is the
// active flag; the remaining bits identify the daemon that owns the capture.
static inline uint64_t rctl_mic_indicator_state(bool active, int pid) {
    return active && pid > 1 ? ((uint64_t)(uint32_t)pid << 1) | 1u : 0;
}

static inline int rctl_mic_indicator_pid(uint64_t state) {
    return (state & 1u) ? (int)(uint32_t)(state >> 1) : 0;
}

static inline bool rctl_mic_indicator_matches(uint64_t state, int pid) {
    return pid > 1 && rctl_mic_indicator_pid(state) == pid;
}

#endif
