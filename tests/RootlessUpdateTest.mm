#import <Foundation/Foundation.h>
#import "protocol/Capabilities.h"
#import "update/UpdateLauncher.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        assert([rctl_device_feature_names() containsObject:@"update.transactional"]);
        assert([rctl_device_feature_names() containsObject:@"update.transactional.rootless"]);
        int status = 0;
        char *body = rctl_update_launch("https://releases.example/update.json", &status);
        // The isolated host prefix deliberately has no updater executable.
        assert(status == 503);
        NSData *data = [NSData dataWithBytes:body length:strlen(body)];
        NSDictionary *response = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        free(body);
        assert([response[@"error"] isEqualToString:@"updater_unavailable"]);
        body = rctl_update_launch("http://releases.example/update.json", &status);
        assert(status == 400);
        free(body);
    }
    puts("RootlessUpdateTest passed");
}
