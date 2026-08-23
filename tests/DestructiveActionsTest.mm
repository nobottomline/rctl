#import <Foundation/Foundation.h>

#include "security/DestructiveActions.h"
#include <assert.h>
#include <stdio.h>

static void expect_path_denied(const char *path) {
    char reason[96] = {};
    assert(!rctl_destructive_path_allowed(path, reason, sizeof(reason)));
    assert(reason[0]);
}

int main(void) {
    @autoreleasepool {
        expect_path_denied("/");
        expect_path_denied("/System");
        expect_path_denied("/System/Library/CoreServices");
        expect_path_denied("/private/var/lib/dpkg/status");
        expect_path_denied("/var/mobile/rctl/index.html");
        expect_path_denied("/private/var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist");

        char reason[96] = {};
        assert(rctl_destructive_path_allowed("/var/mobile/Media/test.jpg", reason, sizeof(reason)));

        NSString *status = @"Package: essential.test\nEssential: yes\nStatus: install ok installed\n\n"
                            "Package: ordinary.test\nStatus: install ok installed\n\n";
        NSString *path = @"/tmp/rctl-destructive-status";
        assert([status writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        assert(!rctl_destructive_package_allowed("com.greatlove.rctl", path.fileSystemRepresentation,
                                                 reason, sizeof(reason)));
        assert(!rctl_destructive_package_allowed("essential.test", path.fileSystemRepresentation,
                                                 reason, sizeof(reason)));
        assert(rctl_destructive_package_allowed("ordinary.test", path.fileSystemRepresentation,
                                                reason, sizeof(reason)));
        assert(!rctl_destructive_package_allowed("not-installed", path.fileSystemRepresentation,
                                                 reason, sizeof(reason)));

        int statusCode = 200;
        char *issued = rctl_destructive_issue("respring", "SpringBoard", &statusCode);
        NSData *data = [NSData dataWithBytes:issued length:strlen(issued)];
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        free(issued);
        NSString *token = json[@"token"];
        assert(token.length == 64);
        assert(rctl_destructive_consume("respring", "SpringBoard", token.UTF8String,
                                        &statusCode, reason, sizeof(reason)));
        assert(!rctl_destructive_consume("respring", "SpringBoard", token.UTF8String,
                                         &statusCode, reason, sizeof(reason)));

        char *updateIssued = rctl_destructive_issue("device_update", "https://releases.example/update.json", &statusCode);
        assert(statusCode == 200);
        free(updateIssued);
        char *badUpdate = rctl_destructive_issue("device_update", "http://releases.example/update.json", &statusCode);
        assert(statusCode == 403);
        free(badUpdate);

        char *localAccess = rctl_destructive_issue("local_access", "relay-only", &statusCode);
        assert(statusCode == 200);
        free(localAccess);
        char *badLocalAccess = rctl_destructive_issue("local_access", "off", &statusCode);
        assert(statusCode == 403);
        free(badLocalAccess);
    }
    puts("DestructiveActionsTest passed");
    return 0;
}
