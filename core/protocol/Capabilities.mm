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
        @"browser": @{@"version": version},
        @"protocol": @{@"major": @(RCTL_PROTOCOL_MAJOR), @"minor": @(RCTL_PROTOCOL_MINOR)},
        @"features": rctl_device_feature_names(),
    };
}
