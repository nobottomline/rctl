#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RCTL_CAMERA_RECORD_PATH "/var/mobile/Library/Caches/com.greatlove.rctl/camera-recording.ts"

bool rctl_camera_ingest_start(void);
void rctl_camera_set_expired_cb(void (*callback)(void));
uint64_t rctl_camera_set_enabled(bool enabled, int position, int fps, int bitrate_bps);
void rctl_camera_renew_lease(void);
bool rctl_camera_is_enabled(void);
char *rctl_camera_status_json(void);
char *rctl_camera_agent_state_json(void);
bool rctl_camera_record_start(void);
void rctl_camera_record_stop(void);
void rctl_camera_record_discard(void);

#ifdef __cplusplus
}
#endif
