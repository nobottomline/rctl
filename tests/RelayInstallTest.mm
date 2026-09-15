#import <Foundation/Foundation.h>
#import "config/RelayInstall.h"
#include <sys/stat.h>
#include <unistd.h>
#include <assert.h>

static NSString *const secret = @"fixture-secret-0000000000000000000000000000";
static NSString *const token = @"fixture-token-00000000000000000000000000000";
static NSDictionary *entry(NSString *url, BOOL paired) {
    return @{@"RelayURL": url, paired ? @"DeviceSecret" : @"EnrollToken": paired ? secret : token, @"Enabled": @YES};
}
static NSDictionary *config(NSArray *entries) {
    return @{@"Enabled": @YES, @"LocalAccessEnabled": @YES, @"Relays": entries};
}
static void writePlist(NSDictionary *value, NSString *path, BOOL binary) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value
        format:binary ? NSPropertyListBinaryFormat_v1_0 : NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    assert([data writeToFile:path atomically:YES]);
    assert(chmod(path.fileSystemRepresentation, 0600) == 0);
}

int main(void) {
    @autoreleasepool {
        NSDictionary *a = entry(@"wss://a.example.test/device", YES);
        NSDictionary *b = entry(@"wss://b.example.test/device", NO);
        NSMutableDictionary *old = [config(@[a]) mutableCopy];
        old[@"DeviceID"] = @"fixture-device-id-0000000000";
        old[@"LocalAccessEnabled"] = @NO;
        old[@"DeviceName"] = @"Existing device";
        NSDictionary *incoming = config(@[b]);
        NSError *error = nil;
        NSDictionary *merged = rctl_relay_install_merge(old, incoming, &error);
        assert(merged && !error && [merged[@"Relays"] count] == 2);
        assert([merged[@"DeviceID"] isEqual:old[@"DeviceID"]]);
        assert([merged[@"LocalAccessEnabled"] isEqual:@NO]);
        assert([merged[@"DeviceName"] isEqual:old[@"DeviceName"]]);
        assert([merged[@"Relays"][0][@"DeviceSecret"] isEqual:secret]);
        assert([merged[@"Relays"][1][@"EnrollToken"] isEqual:token]);
        assert([rctl_relay_install_merge(merged, incoming, nil) isEqual:merged]);
        NSDictionary *same = config(@[entry(@"wss://A.example.test:443/device", NO)]);
        NSDictionary *sameResult = rctl_relay_install_merge(old, same, nil);
        assert([sameResult[@"Relays"] count] == 1);
        assert([sameResult[@"Relays"][0][@"DeviceSecret"] isEqual:secret]);
        assert(!sameResult[@"Relays"][0][@"EnrollToken"]);

        NSMutableDictionary *legacy = [a mutableCopy];
        legacy[@"DeviceID"] = old[@"DeviceID"];
        legacy[@"LocalAccessEnabled"] = @NO;
        NSDictionary *migrated = rctl_relay_install_merge(legacy, incoming, nil);
        assert([migrated[@"Relays"] count] == 2 && !migrated[@"DeviceSecret"] && !migrated[@"RelayURL"]);
        assert(!migrated[@"Relays"][0][@"DeviceID"]);
        assert([migrated[@"LocalAccessEnabled"] isEqual:@NO]);
        old[@"Enabled"] = @NO;
        assert([rctl_relay_install_merge(old, incoming, nil)[@"Enabled"] isEqual:@NO]);
        NSMutableDictionary *disabled = [a mutableCopy]; disabled[@"Enabled"] = @NO;
        assert([rctl_relay_install_merge(config(@[disabled]), same, nil)[@"Relays"][0][@"Enabled"] isEqual:@NO]);

        NSMutableDictionary *renewed = [b mutableCopy]; renewed[@"EnrollToken"] = [token stringByAppendingString:@"renewed"];
        assert([rctl_relay_install_merge(config(@[b]), config(@[renewed]), nil)[@"Relays"][0][@"EnrollToken"] isEqual:renewed[@"EnrollToken"]]);
        assert([rctl_relay_install_merge(nil, incoming, nil)[@"Relays"] isEqual:incoming[@"Relays"]]);
        assert(rctl_relay_install_merge(old, nil, nil));
        NSMutableDictionary *pending = [config(@[b]) mutableCopy];
        pending[@"DeviceID"] = old[@"DeviceID"];
        NSMutableDictionary *approved = [config(@[entry(b[@"RelayURL"], YES)]) mutableCopy];
        approved[@"DeviceID"] = old[@"DeviceID"];
        NSDictionary *retry = rctl_relay_install_merge(pending, approved, nil);
        assert([retry[@"Relays"][0][@"DeviceSecret"] isEqual:secret] && !retry[@"Relays"][0][@"EnrollToken"]);
        approved[@"DeviceID"] = @"another-fixture-device-identity";
        assert(!rctl_relay_install_merge(pending, approved, nil)[@"Relays"][0][@"DeviceSecret"]);
        for (id bad in @[@[], @{@"Relays": @"invalid"}, config(@[a, a]), config(@[@{@"RelayURL": @"http://unsafe.test", @"EnrollToken": token}]), config(@[@{@"RelayURL": @"wss://a.example.test", @"EnrollToken": @"short"}])]) {
            error = nil;
            assert(!rctl_relay_install_merge(old, bad, &error) && error);
        }
        NSMutableArray *many = [NSMutableArray array];
        for (int i = 0; i < 65; i++) [many addObject:entry([NSString stringWithFormat:@"wss://host-%d.example.test/device", i], NO)];
        assert(!rctl_relay_install_merge(nil, config(many), nil));

        char directory[] = "/tmp/rctl-relay-install.XXXXXX";
        assert(mkdtemp(directory));
        NSString *root = @(directory);
        NSString *path = [root stringByAppendingPathComponent:@"config.plist"];
        NSString *backup = [root stringByAppendingPathComponent:@"backup.plist"];
        for (NSNumber *binary in @[@NO, @YES]) {
            writePlist(old, path, binary.boolValue);
            assert(rctl_relay_install_preserve(path, backup, nil));
            writePlist(incoming, path, binary.boolValue);
            assert(rctl_relay_install_apply(path, backup, getuid(), getgid(), nil));
            NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:path];
            assert([stored[@"Relays"] count] == 2 && [stored[@"DeviceID"] isEqual:old[@"DeviceID"]]);
            assert(access(backup.fileSystemRepresentation, F_OK) != 0);
            assert(rctl_relay_install_apply(path, backup, getuid(), getgid(), nil));
            assert([stored isEqual:[NSDictionary dictionaryWithContentsOfFile:path]]);
            struct stat st = {}; assert(stat(path.fileSystemRepresentation, &st) == 0);
            assert((st.st_mode & 0777) == 0600 && st.st_uid == getuid());
            // Public upgrades do not ship a config, including remove/install transactions.
            assert(rctl_relay_install_preserve(path, backup, nil));
            assert(unlink(path.fileSystemRepresentation) == 0);
            assert(rctl_relay_install_apply(path, backup, getuid(), getgid(), nil));
            assert([stored isEqual:[NSDictionary dictionaryWithContentsOfFile:path]]);
        }
        assert(rctl_relay_install_preserve(path, backup, nil));
        NSData *originalBackup = [NSData dataWithContentsOfFile:backup];
        NSData *broken = [@"not a plist" dataUsingEncoding:NSUTF8StringEncoding];
        assert([broken writeToFile:path atomically:NO]);
        assert(!rctl_relay_install_apply(path, backup, getuid(), getgid(), nil));
        assert([originalBackup isEqual:[NSData dataWithContentsOfFile:backup]]);
        assert([broken isEqual:[NSData dataWithContentsOfFile:path]]);
        assert(unlink(path.fileSystemRepresentation) == 0);
        assert(symlink(backup.fileSystemRepresentation, path.fileSystemRepresentation) == 0);
        assert(!rctl_relay_install_apply(path, backup, getuid(), getgid(), nil));
        assert(unlink(path.fileSystemRepresentation) == 0);
        assert(chmod(backup.fileSystemRepresentation, 0644) == 0);
        assert(!rctl_relay_install_apply(path, backup, getuid(), getgid(), nil));
        // Missing config clears stale backup; a later public install stays LAN-only.
        assert(rctl_relay_install_preserve(path, backup, nil));
        assert(rctl_relay_install_apply(path, backup, getuid(), getgid(), nil));
        assert(access(path.fileSystemRepresentation, F_OK) != 0);
        assert([NSFileManager.defaultManager removeItemAtPath:root error:nil]);
        puts("Relay installation tests passed");
    }
}
