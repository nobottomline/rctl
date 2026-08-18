#import "CameraAgent.h"

extern "C" void rctl_virtual_mic_initialize(void);

extern "C" void rctl_app_media_initialize(rctl_camera_tcc_callback tcc_callback) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rctl_camera_agent_initialize(tcc_callback);
        rctl_virtual_mic_initialize();
    });
}
