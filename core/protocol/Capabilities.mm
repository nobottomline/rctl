#import "Capabilities.h"

NSArray<NSString *> *rctl_device_feature_names(void) {
    static NSArray<NSString *> *features;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        features = @[
            @"screen.webrtc",
            @"camera.live",
            @"audio.playback",
            @"audio.room_mic",
            @"audio.virtual_mic",
            @"files.streaming",
            @"media.library",
            @"terminal.pty",
            @"destructive.confirmation",
            @"update.transactional",
#if defined(RCTL_ROOTLESS)
            @"update.transactional.rootless",
#endif
            @"network.local_access_policy",
            @"controller.scoped_sessions",
            @"controller.authorization_lease_v1",
            @"state.orientation",
        ];
    });
    return features;
}

NSDictionary *rctl_device_capabilities(void) {
    NSString *version = @RCTL_VERSION;
    return @{
        @"product": @"rctl",
        @"component": @"daemon",
        @"daemon": @{@"version": version},
#if defined(RCTL_PACKAGE_VERSION)
        @"package_version": @RCTL_PACKAGE_VERSION,
#endif
        @"browser": @{@"version": version},
        @"protocol": @{@"major": @(RCTL_PROTOCOL_MAJOR), @"minor": @(RCTL_PROTOCOL_MINOR)},
        @"features": rctl_device_feature_names(),
    };
}
