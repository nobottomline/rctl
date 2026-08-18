#include "net/MediaActivityPolicy.h"

#include <stdio.h>
#include <stdlib.h>

static void require(bool condition, const char *message) {
    if (condition) return;
    fprintf(stderr, "media activity policy test failed: %s\n", message);
    exit(1);
}

int main() {
    for (int stream = 0; stream <= 1; stream++) {
        for (int webrtc = 0; webrtc <= 1; webrtc++) {
            rctl_media_activity_state camera =
                rctl_media_activity_policy(true, stream != 0, webrtc != 0);
            require(!camera.screen_capture, "camera must pause screen capture");
            require(camera.keep_awake, "camera must prevent Auto-Lock");
        }
    }

    rctl_media_activity_state idle = rctl_media_activity_policy(false, false, false);
    require(!idle.screen_capture && !idle.keep_awake, "idle must release all media work");

    rctl_media_activity_state stream = rctl_media_activity_policy(false, true, false);
    require(stream.screen_capture && stream.keep_awake, "stream viewer must activate screen");

    rctl_media_activity_state webrtc = rctl_media_activity_policy(false, false, true);
    require(webrtc.screen_capture && webrtc.keep_awake, "WebRTC viewer must activate screen");

    puts("media activity policy test passed");
    return 0;
}
