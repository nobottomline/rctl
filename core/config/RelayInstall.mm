#import "RelayInstall.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static BOOL fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"rctl.relay.install" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

static NSString *relayKey(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSURLComponents *url = [NSURLComponents componentsWithString:value];
    if (![url.scheme.lowercaseString isEqualToString:@"wss"] || !url.host.length ||
        url.user || url.password || url.query || url.fragment) return nil;
    url.scheme = @"wss";
    url.host = url.host.lowercaseString;
    if (url.port && (url.port.integerValue < 1 || url.port.integerValue > 65535)) return nil;
    if (url.port.integerValue == 443) url.port = nil;
    if (!url.path.length) url.path = @"/";
    return url.string;
}

static NSArray *entries(NSDictionary *root, NSError **error) {
    if (!root) return @[];
    if (![root isKindOfClass:NSDictionary.class]) { fail(error, @"Relay configuration must be a dictionary"); return nil; }
    for (NSString *key in @[@"Enabled", @"LocalAccessEnabled"]) {
        if (root[key] && ![root[key] isKindOfClass:NSNumber.class]) {
            fail(error, @"Invalid relay policy flag"); return nil;
        }
    }
    if (root[@"DeviceID"] && (![root[@"DeviceID"] isKindOfClass:NSString.class] || [root[@"DeviceID"] length] < 16)) {
        fail(error, @"Invalid relay device identity"); return nil;
    }
    id list = root[@"Relays"] ?: @[root];
    if (![list isKindOfClass:NSArray.class] || [list count] > 64) {
        fail(error, @"Invalid relay list or too many entries"); return nil;
    }
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *result = [NSMutableArray array];
    for (id item in list) {
        if (![item isKindOfClass:NSDictionary.class]) { fail(error, @"Invalid relay entry"); return nil; }
        NSString *key = relayKey(item[@"RelayURL"]);
        id secret = item[@"DeviceSecret"], token = item[@"EnrollToken"];
        BOOL validSecret = [secret isKindOfClass:NSString.class] && [secret length] >= 32;
        BOOL validToken = [token isKindOfClass:NSString.class] && [token length] >= 32;
        if (!key || [seen containsObject:key] || (!validSecret && !validToken) ||
            (secret && !validSecret) || (token && !validToken) ||
            (item[@"Enabled"] && ![item[@"Enabled"] isKindOfClass:NSNumber.class])) {
            fail(error, @"Invalid or duplicate relay entry"); return nil;
        }
        [seen addObject:key];
        NSMutableDictionary *entry = [item mutableCopy];
        // Legacy single-relay dictionaries also carry device-wide properties.
        for (NSString *global in @[@"DeviceID", @"LocalAccessEnabled", @"Relays"]) [entry removeObjectForKey:global];
        if (!entry[@"DeviceName"] && root[@"DeviceName"]) entry[@"DeviceName"] = root[@"DeviceName"];
        if (validSecret) [entry removeObjectForKey:@"EnrollToken"];
        [result addObject:entry];
    }
    return result;
}

NSDictionary *rctl_relay_install_merge(NSDictionary *installed, NSDictionary *incoming, NSError **error) {
    NSArray *oldEntries = entries(installed, error);
    if (!oldEntries) return nil;
    NSArray *newEntries = entries(incoming, error);
    if (!newEntries) return nil;
    if (!installed && !incoming) return @{};
    NSMutableDictionary *merged = [(installed ?: incoming) mutableCopy];
    NSMutableArray *all = [oldEntries mutableCopy];
    NSMutableDictionary *indexes = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < all.count; i++) indexes[relayKey(all[i][@"RelayURL"])] = @(i);
    for (NSDictionary *entry in newEntries) {
        NSString *key = relayKey(entry[@"RelayURL"]);
        NSNumber *index = indexes[key];
        if (index) {
            // A fresh enrollment can renew a pending token, never an established identity.
            NSMutableDictionary *existing = [all[index.unsignedIntegerValue] mutableCopy];
            if (!existing[@"DeviceSecret"] && entry[@"EnrollToken"]) existing[@"EnrollToken"] = entry[@"EnrollToken"];
            if (!existing[@"DeviceSecret"] && entry[@"DeviceSecret"] &&
                installed[@"DeviceID"] && [installed[@"DeviceID"] isEqual:incoming[@"DeviceID"]]) {
                existing[@"DeviceSecret"] = entry[@"DeviceSecret"];
                [existing removeObjectForKey:@"EnrollToken"];
            }
            all[index.unsignedIntegerValue] = existing;
        } else {
            indexes[key] = @(all.count);
            NSMutableDictionary *added = [entry mutableCopy];
            if (!added[@"DeviceName"] && merged[@"DeviceName"]) added[@"DeviceName"] = merged[@"DeviceName"];
            [all addObject:added];
        }
    }
    if (all.count > 64) { fail(error, @"Too many relay entries after merge"); return nil; }
    for (NSString *key in @[@"RelayURL", @"DeviceSecret", @"EnrollToken"]) [merged removeObjectForKey:key];
    merged[@"Relays"] = all;
    return merged;
}

// Configs may be XML or binary. Never follow links or echo plist content/errors.
static BOOL readConfig(NSString *path, BOOL backup, NSDictionary **result, NSError **error) {
    *result = nil;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return errno == ENOENT ? YES : fail(error, @"Cannot safely open relay configuration");
    struct stat st = {};
    BOOL safe = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_nlink == 1 &&
                st.st_size > 0 && st.st_size <= 1024 * 1024 && !(st.st_mode & 0022) &&
                (backup ? st.st_uid == geteuid() && !(st.st_mode & 0077) : (st.st_uid == geteuid() || st.st_uid == 501));
    if (!safe) { close(fd); return fail(error, @"Unsafe relay configuration file metadata"); }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    size_t offset = 0;
    while (offset < data.length) {
        ssize_t n = read(fd, (char *)data.mutableBytes + offset, data.length - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return fail(error, @"Cannot read relay configuration"); }
        offset += (size_t)n;
    }
    close(fd);
    id root = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
    if (![root isKindOfClass:NSDictionary.class] || !entries(root, error)) return fail(error, @"Invalid relay configuration; original files retained");
    *result = root;
    return YES;
}

static BOOL writeConfig(NSDictionary *root, NSString *path, uid_t owner, gid_t group, NSError **error) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:root format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    if (!data) return fail(error, @"Cannot serialize relay configuration");
    char *temporary = strdup([[path stringByAppendingString:@".XXXXXX"] fileSystemRepresentation]);
    int fd = mkstemp(temporary);
    if (fd < 0) { free(temporary); return fail(error, @"Cannot stage relay configuration"); }
    BOOL ok = fchmod(fd, 0600) == 0 && fchown(fd, owner, group) == 0;
    size_t offset = 0;
    while (ok && offset < data.length) {
        ssize_t n = write(fd, (const char *)data.bytes + offset, data.length - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ok = NO; break; }
        offset += (size_t)n;
    }
    if (ok) ok = fsync(fd) == 0;
    if (close(fd) != 0) ok = NO;
    if (ok) ok = rename(temporary, path.fileSystemRepresentation) == 0;
    if (!ok) unlink(temporary);
    free(temporary);
    return ok ? YES : fail(error, @"Cannot commit relay configuration; backup retained");
}

BOOL rctl_relay_install_preserve(NSString *config, NSString *backup, NSError **error) {
    NSDictionary *root = nil;
    if (!readConfig(config, NO, &root, error)) return NO;
    if (!root) return unlink(backup.fileSystemRepresentation) == 0 || errno == ENOENT ? YES : fail(error, @"Cannot clear stale relay backup");
    return writeConfig(root, backup, geteuid(), getegid(), error);
}

BOOL rctl_relay_install_apply(NSString *config, NSString *backup, uid_t owner, gid_t group, NSError **error) {
    NSDictionary *installed = nil, *incoming = nil;
    if (!readConfig(backup, YES, &installed, error) || !readConfig(config, NO, &incoming, error)) return NO;
    if (!installed && !incoming) return YES;
    NSDictionary *merged = rctl_relay_install_merge(installed, incoming, error);
    if (!merged || !writeConfig(merged, config, owner, group, error)) return NO;
    if (unlink(backup.fileSystemRepresentation) != 0 && errno != ENOENT) return fail(error, @"Cannot remove consumed relay backup");
    return YES;
}
