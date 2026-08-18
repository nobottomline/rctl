#pragma once

#include <stdbool.h>

typedef struct {
    bool screen_capture;
    bool keep_awake;
} rctl_media_activity_state;

static inline rctl_media_activity_state rctl_media_activity_policy(
    bool camera_live, bool stream_viewer, bool webrtc_viewer) {
    if (camera_live) {
        rctl_media_activity_state camera = {false, true};
        return camera;
    }
    bool viewer = stream_viewer || webrtc_viewer;
    rctl_media_activity_state screen = {viewer, viewer};
    return screen;
}
