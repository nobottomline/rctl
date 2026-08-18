#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rctl_ts_recorder rctl_ts_recorder;

rctl_ts_recorder *rctl_ts_recorder_open(const char *path);
bool rctl_ts_recorder_write(rctl_ts_recorder *recorder, const uint8_t *annex_b,
                            size_t length, bool keyframe, uint64_t pts_us);
void rctl_ts_recorder_close(rctl_ts_recorder *recorder);
uint64_t rctl_ts_recorder_bytes(const rctl_ts_recorder *recorder);
uint64_t rctl_ts_recorder_duration_ms(const rctl_ts_recorder *recorder);

#ifdef __cplusplus
}
#endif
