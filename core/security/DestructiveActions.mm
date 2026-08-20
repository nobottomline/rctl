#import "DestructiveActions.h"

#import <Foundation/Foundation.h>
#import <pthread.h>
#import <limits.h>
#import <sys/stat.h>
#import <time.h>

namespace {

constexpr time_t kTokenLifetimeSeconds = 30;
constexpr size_t kMaximumTokens = 32;

struct Confirmation {
    char token[65];
    char action[32];
    char target[PATH_MAX];
    time_t expires_at;
    bool used;
};

Confirmation gConfirmations[kMaximumTokens] = {};
pthread_mutex_t gConfirmationLock = PTHREAD_MUTEX_INITIALIZER;

void set_reason(char *out, size_t len, const char *value) {
    if (!out || len == 0) return;
    snprintf(out, len, "%s", value ?: "rejected");
}

bool is_at_or_below(NSString *path, NSString *root) {
    return [path isEqualToString:root] || [path hasPrefix:[root stringByAppendingString:@"/"]];
}

bool safe_package_id(const char *value) {
    if (!value || !*value) return false;
    for (const char *p = value; *p; ++p) {
        const char c = *p;
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '.' || c == '+' ||
              c == '-' || c == '_')) return false;
    }
    return true;
}

bool normalize_target(const char *action, const char *target, char *out,
                      size_t out_len, char *reason, size_t reason_len) {
    if (!action || !target || !*target || !out || out_len == 0) {
        set_reason(reason, reason_len, "action_and_target_required");
        return false;
    }
    if (!strcmp(action, "file_delete")) {
        if (!rctl_destructive_normalize_path(target, out, out_len)) {
            set_reason(reason, reason_len, "invalid_path");
            return false;
        }
        return rctl_destructive_path_allowed(out, reason, reason_len);
    }
    if (!strcmp(action, "package_remove")) {
        if (!safe_package_id(target) || strlen(target) >= out_len) {
            set_reason(reason, reason_len, "invalid_package_id");
            return false;
        }
        strcpy(out, target);
        return rctl_destructive_package_allowed(target, nullptr, reason, reason_len);
    }
    if (!strcmp(action, "tweak_toggle")) {
        if (!rctl_destructive_normalize_path(target, out, out_len)) {
            set_reason(reason, reason_len, "invalid_tweak_path");
            return false;
        }
        NSString *path = [NSString stringWithUTF8String:out] ?: @"";
        NSString *name = path.lastPathComponent.lowercaseString;
        if ([name hasPrefix:@"rctl"] || [name containsString:@"com.greatlove.rctl"]) {
            set_reason(reason, reason_len, "rctl_runtime_protected");
            return false;
        }
        return true;
    }
    if (!strcmp(action, "respring")) {
        if (strcmp(target, "SpringBoard") || strlen(target) >= out_len) {
            set_reason(reason, reason_len, "invalid_respring_target");
            return false;
        }
        strcpy(out, target);
        return true;
    }
    set_reason(reason, reason_len, "unsupported_action");
    return false;
}

NSString *installed_status_database(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *path in @[@"/var/lib/dpkg/status", @"/var/jb/var/lib/dpkg/status"]) {
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

}  // namespace

bool rctl_destructive_normalize_path(const char *path, char *normalized,
                                     size_t normalized_len) {
    if (!path || path[0] != '/' || !normalized || normalized_len == 0) return false;
    NSString *raw = [NSString stringWithUTF8String:path];
    if (!raw || [raw rangeOfString:@"\0"].location != NSNotFound) return false;

    NSString *standard = raw.stringByStandardizingPath;
    if (![standard hasPrefix:@"/"]) return false;

    // Resolve symlinks for an existing target. This deliberately rejects a
    // symlink into a protected tree even though unlinking the link itself would
    // not modify the destination; destructive root operations should fail safe.
    char resolved[PATH_MAX];
    if (realpath(standard.fileSystemRepresentation, resolved)) {
        standard = [NSString stringWithUTF8String:resolved] ?: standard;
    } else {
        NSString *parent = standard.stringByDeletingLastPathComponent;
        char resolved_parent[PATH_MAX];
        if (!realpath(parent.fileSystemRepresentation, resolved_parent)) return false;
        NSString *resolvedParent = [NSString stringWithUTF8String:resolved_parent];
        standard = [resolvedParent stringByAppendingPathComponent:standard.lastPathComponent];
    }
    const char *utf8 = standard.fileSystemRepresentation;
    if (!utf8 || strlen(utf8) >= normalized_len) return false;
    strcpy(normalized, utf8);
    return true;
}

bool rctl_destructive_path_allowed(const char *path, char *reason,
                                   size_t reason_len) {
    NSString *value = [NSString stringWithUTF8String:path ?: ""];
    if (!value || ![value hasPrefix:@"/"]) {
        set_reason(reason, reason_len, "invalid_path");
        return false;
    }

    NSArray<NSString *> *protectedTrees = @[
        @"/System", @"/Library", @"/usr", @"/bin", @"/sbin",
        @"/Applications", @"/etc", @"/private/etc",
        @"/var/lib/dpkg", @"/private/var/lib/dpkg", @"/var/jb/var/lib/dpkg",
        @"/var/lib/apt", @"/private/var/lib/apt", @"/var/jb/var/lib/apt",
        @"/var/cache/apt", @"/private/var/cache/apt", @"/var/jb/var/cache/apt",
        @"/var/mobile/rctl", @"/private/var/mobile/rctl",
        @"/var/mobile/Library/Caches/com.greatlove.rctl",
        @"/private/var/mobile/Library/Caches/com.greatlove.rctl",
    ];
    if ([value isEqualToString:@"/"]) {
        set_reason(reason, reason_len, "filesystem_root_protected");
        return false;
    }
    for (NSString *root in protectedTrees) {
        if (is_at_or_below(value, root)) {
            set_reason(reason, reason_len, "protected_system_path");
            return false;
        }
    }
    NSArray<NSString *> *protectedFiles = @[
        @"/var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist",
        @"/private/var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist",
    ];
    if ([protectedFiles containsObject:value]) {
        set_reason(reason, reason_len, "rctl_identity_protected");
        return false;
    }
    return true;
}

bool rctl_destructive_package_allowed(const char *package_id,
                                      const char *status_database,
                                      char *reason, size_t reason_len) {
    if (!safe_package_id(package_id)) {
        set_reason(reason, reason_len, "invalid_package_id");
        return false;
    }
    if (!strcmp(package_id, "com.greatlove.rctl")) {
        set_reason(reason, reason_len, "rctl_package_protected");
        return false;
    }

    NSString *database = status_database ? [NSString stringWithUTF8String:status_database]
                                         : installed_status_database();
    NSString *raw = database ? [NSString stringWithContentsOfFile:database
                                                          encoding:NSUTF8StringEncoding
                                                             error:nil] : nil;
    if (!raw) {
        // Package removal without authoritative package metadata is unsafe.
        set_reason(reason, reason_len, "package_database_unavailable");
        return false;
    }
    NSString *wanted = [NSString stringWithUTF8String:package_id];
    for (NSString *stanza in [raw componentsSeparatedByString:@"\n\n"]) {
        NSString *found = nil;
        bool essential = false;
        bool installed = false;
        for (NSString *line in [stanza componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"Package: "]) found = [line substringFromIndex:9];
            else if ([line caseInsensitiveCompare:@"Essential: yes"] == NSOrderedSame) essential = true;
            else if ([line hasPrefix:@"Status: "] && [line containsString:@" installed"]) installed = true;
        }
        if (![found isEqualToString:wanted]) continue;
        if (!installed) {
            set_reason(reason, reason_len, "package_not_installed");
            return false;
        }
        if (essential) {
            set_reason(reason, reason_len, "essential_package_protected");
            return false;
        }
        return true;
    }
    set_reason(reason, reason_len, "package_not_installed");
    return false;
}

char *rctl_destructive_issue(const char *action, const char *target, int *status) {
    char normalized[PATH_MAX] = {};
    char reason[96] = {};
    if (!normalize_target(action, target, normalized, sizeof(normalized), reason, sizeof(reason))) {
        if (status) *status = 403;
        NSString *message = [NSString stringWithUTF8String:reason] ?: @"rejected";
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"error": message} options:0 error:nil];
        char *result = static_cast<char *>(malloc(data.length + 1));
        memcpy(result, data.bytes, data.length); result[data.length] = 0;
        return result;
    }

    uint8_t random[32];
    arc4random_buf(random, sizeof(random));
    char token[65];
    for (size_t i = 0; i < sizeof(random); ++i) snprintf(token + i * 2, 3, "%02x", random[i]);

    const time_t now = time(nullptr);
    pthread_mutex_lock(&gConfirmationLock);
    size_t slot = kMaximumTokens;
    for (size_t i = 0; i < kMaximumTokens; ++i) {
        if (gConfirmations[i].used || gConfirmations[i].expires_at <= now) { slot = i; break; }
    }
    if (slot == kMaximumTokens) slot = static_cast<size_t>(arc4random_uniform(kMaximumTokens));
    Confirmation &entry = gConfirmations[slot];
    snprintf(entry.token, sizeof(entry.token), "%s", token);
    snprintf(entry.action, sizeof(entry.action), "%s", action);
    snprintf(entry.target, sizeof(entry.target), "%s", normalized);
    entry.expires_at = now + kTokenLifetimeSeconds;
    entry.used = false;
    pthread_mutex_unlock(&gConfirmationLock);

    NSDictionary *json = @{@"token": @(token), @"action": @(action),
                           @"target": @(normalized), @"expires_in": @(kTokenLifetimeSeconds)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    char *result = static_cast<char *>(malloc(data.length + 1));
    memcpy(result, data.bytes, data.length); result[data.length] = 0;
    return result;
}

bool rctl_destructive_consume(const char *action, const char *target,
                              const char *token, int *status,
                              char *error, size_t error_len) {
    char normalized[PATH_MAX] = {};
    if (!token || strlen(token) != 64 ||
        !normalize_target(action, target, normalized, sizeof(normalized), error, error_len)) {
        if (status) *status = 403;
        return false;
    }
    const time_t now = time(nullptr);
    bool accepted = false;
    pthread_mutex_lock(&gConfirmationLock);
    for (Confirmation &entry : gConfirmations) {
        if (entry.used || entry.expires_at <= now) continue;
        if (!strcmp(entry.token, token)) {
            // Consume matching and mismatching tokens alike. A token is a single
            // attempt, not a reusable capability that can be probed for targets.
            entry.used = true;
            accepted = !strcmp(entry.action, action) && !strcmp(entry.target, normalized);
            break;
        }
    }
    pthread_mutex_unlock(&gConfirmationLock);
    if (!accepted) {
        if (status) *status = 403;
        set_reason(error, error_len, "confirmation_invalid_or_expired");
    }
    return accepted;
}
