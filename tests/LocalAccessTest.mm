#import <Foundation/Foundation.h>

#include "config/LocalAccess.h"
#include <assert.h>
#include <stdio.h>

static NSString *const configPath = @"/tmp/rctl-local-access-test.plist";

static void write_config(NSDictionary *config) {
    assert([config writeToFile:configPath atomically:YES]);
}

int main(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager] removeItemAtPath:configPath error:nil];
        assert(rctl_local_access_enabled());

        char error[128] = {};
        assert(!rctl_local_access_set_enabled(false, error, sizeof(error)));
        assert(!strcmp(error, "relay_config_unavailable"));

        write_config(@{
            @"Enabled": @YES,
            @"DeviceName": @"Test iPad",
            @"Relays": @[@{
                @"Enabled": @YES,
                @"RelayURL": @"wss://relay.example.test/device",
                @"EnrollToken": @"enroll_abcdefghijklmnopqrstuvwxyz0123456789",
            }],
        });
        memset(error, 0, sizeof(error));
        assert(!rctl_local_access_set_enabled(false, error, sizeof(error)));
        assert(!strcmp(error, "approved_relay_required"));

        write_config(@{
            @"Enabled": @YES,
            @"DeviceName": @"Test iPad",
            @"Relays": @[@{
                @"Enabled": @YES,
                @"RelayURL": @"wss://relay.example.test/device",
                @"DeviceSecret": @"device_abcdefghijklmnopqrstuvwxyz0123456789",
            }],
        });
        assert(rctl_local_access_set_enabled(false, error, sizeof(error)));
        assert(!rctl_local_access_enabled());
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:configPath];
        assert([saved[@"DeviceName"] isEqualToString:@"Test iPad"]);
        assert([saved[@"LocalAccessEnabled"] isEqual:@NO]);

        assert(rctl_local_access_set_enabled(true, error, sizeof(error)));
        assert(rctl_local_access_enabled());
        [[NSFileManager defaultManager] removeItemAtPath:configPath error:nil];
    }
    puts("LocalAccessTest passed");
    return 0;
}
