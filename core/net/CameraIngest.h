#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool rctl_camera_ingest_start(void);
uint64_t rctl_camera_set_enabled(bool enabled, int position, int fps, int bitrate_bps);
bool rctl_camera_is_enabled(void);
char *rctl_camera_status_json(void);
char *rctl_camera_agent_state_json(void);

#ifdef __cplusplus
}
#endif
