#import "LocalAccess.h"

#import <Foundation/Foundation.h>
#import <pthread.h>

#ifndef RCTL_RELAY_CONFIG_PLIST
#define RCTL_RELAY_CONFIG_PLIST @"/var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist"
#endif

namespace {

pthread_mutex_t gRelayConfigLock = PTHREAD_MUTEX_INITIALIZER;

void set_error(char *out, size_t len, const char *value) {
    if (!out || len == 0) return;
    snprintf(out, len, "%s", value ?: "local_access_update_failed");
}

bool entry_has_approved_identity(NSDictionary *entry) {
    if (![entry isKindOfClass:[NSDictionary class]]) return false;
    if ([entry[@"Enabled"] respondsToSelector:@selector(boolValue)] &&
        ![entry[@"Enabled"] boolValue]) return false;
    NSString *url = [entry[@"RelayURL"] isKindOfClass:[NSString class]] ? entry[@"RelayURL"] : nil;
    NSString *secret = [entry[@"DeviceSecret"] isKindOfClass:[NSString class]] ? entry[@"DeviceSecret"] : nil;
    return [url hasPrefix:@"wss://"] && secret.length >= 32;
}

bool has_approved_relay(NSDictionary *root) {
    if (![root isKindOfClass:[NSDictionary class]]) return false;
    if ([root[@"Enabled"] respondsToSelector:@selector(boolValue)] &&
        ![root[@"Enabled"] boolValue]) return false;
    NSArray *relays = [root[@"Relays"] isKindOfClass:[NSArray class]] ? root[@"Relays"] : nil;
    if (!relays) return entry_has_approved_identity(root); // legacy single-relay schema
    for (id entry in relays) {
        if (entry_has_approved_identity(entry)) return true;
    }
    return false;
}

} // namespace

void rctl_relay_config_lock(void) {
    pthread_mutex_lock(&gRelayConfigLock);
}

void rctl_relay_config_unlock(void) {
    pthread_mutex_unlock(&gRelayConfigLock);
}

bool rctl_local_access_enabled(void) {
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:RCTL_RELAY_CONFIG_PLIST];
    NSNumber *value = [root[@"LocalAccessEnabled"] isKindOfClass:[NSNumber class]]
        ? root[@"LocalAccessEnabled"] : nil;
    return value ? value.boolValue : true;
}

bool rctl_local_access_set_enabled(bool enabled, char *error, size_t error_len) {
    @autoreleasepool {
        rctl_relay_config_lock();
        NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:RCTL_RELAY_CONFIG_PLIST];
        if (![existing isKindOfClass:[NSDictionary class]]) {
            rctl_relay_config_unlock();
            set_error(error, error_len, "relay_config_unavailable");
            return false;
        }
        if (!enabled && !has_approved_relay(existing)) {
            rctl_relay_config_unlock();
            set_error(error, error_len, "approved_relay_required");
            return false;
        }
        NSMutableDictionary *updated = [existing mutableCopy];
        updated[@"LocalAccessEnabled"] = @(enabled);
        if (![updated writeToFile:RCTL_RELAY_CONFIG_PLIST atomically:YES]) {
            rctl_relay_config_unlock();
            set_error(error, error_len, "relay_config_write_failed");
            return false;
        }
        rctl_relay_config_unlock();
        return true;
    }
}
