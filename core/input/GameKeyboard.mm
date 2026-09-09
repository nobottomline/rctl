#import "GameKeyboard.h"
#include "KeyboardLease.h"
#import "ScriptValidation.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <QuartzCore/QuartzCore.h>

namespace {
using Ref = CFTypeRef;
// Legacy callback ABI used by Apple's IOHIDFamily TestVirtualService.m.
struct Callbacks {
    void (*notify)(void *, void *, Ref, uint32_t, CFDictionaryRef);
    bool (*setProperty)(void *, void *, Ref, CFStringRef, CFTypeRef);
    Ref (*copyProperty)(void *, void *, Ref, CFStringRef);
    Ref (*copyEvent)(void *, void *, Ref, uint32_t, Ref, uint32_t);
    int (*outputEvent)(void *, void *, Ref, Ref);
};
struct HID {
    Ref (*clientCreate)(CFAllocatorRef, int, CFDictionaryRef);
    void (*schedule)(Ref, dispatch_queue_t);
    void (*unschedule)(Ref, dispatch_queue_t);
    Ref (*serviceCreate)(Ref, CFDictionaryRef, Callbacks, void *, void *);
    void (*remove)(Ref);
    bool (*send)(Ref, Ref);
    Ref (*key)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, bool, uint32_t);
} hid;
Ref client, service;
dispatch_queue_t queue;
dispatch_source_t timer;
NSMutableDictionary *properties;
rctl::KeyboardLease lease;

uint64_t nowMS() { return (uint64_t)(CACurrentMediaTime() * 1000); }
void notified(void *, void *, Ref, uint32_t, CFDictionaryRef) {}
bool setProperty(void *, void *, Ref, CFStringRef key, Ref value) {
    if (!key || !value) return false;
    properties[(__bridge NSString *)key] = (__bridge id)value;
    return true;
}
Ref copyProperty(void *, void *, Ref, CFStringRef key) {
    id value = key ? properties[(__bridge NSString *)key] : nil;
    return value ? CFRetain((__bridge Ref)value) : NULL;
}
Ref copyEvent(void *, void *, Ref, uint32_t, Ref, uint32_t) { return NULL; }
int outputEvent(void *, void *, Ref, Ref) { return 0; }

bool available() {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
#define LOAD(member, symbol) hid.member = (decltype(hid.member))dlsym(RTLD_DEFAULT, symbol)
        LOAD(clientCreate, "IOHIDEventSystemClientCreateWithType");
        LOAD(schedule, "IOHIDEventSystemClientScheduleWithDispatchQueue");
        LOAD(unschedule, "IOHIDEventSystemClientUnscheduleFromDispatchQueue");
        LOAD(serviceCreate, "IOHIDVirtualServiceClientCreate");
        LOAD(remove, "IOHIDVirtualServiceClientRemove");
        LOAD(send, "IOHIDVirtualServiceClientDispatchEvent");
        LOAD(key, "IOHIDEventCreateKeyboardEvent");
#undef LOAD
    });
    return hid.clientCreate && hid.schedule && hid.unschedule && hid.serviceCreate && hid.remove && hid.send && hid.key;
}

bool emit(uint16_t usage, bool down) {
    __block bool ok = false;
    dispatch_sync(queue, ^{
        Ref event = hid.key(kCFAllocatorDefault, mach_absolute_time(), 7, usage, down, 0);
        if (event) { ok = hid.send(service, event); CFRelease(event); }
    });
    return ok;
}

NSString *json(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
NSString *failure(NSString *reason) { return json(@{@"error": reason}); }
NSString *success() {
    return json(@{@"ok": @YES, @"active": @(!lease.owner.empty()),
                  @"lease_ms": @(rctl::KeyboardLease::durationMS), @"sequence": @(lease.sequence)});
}

bool start() {
    if (!available()) return false;
    // Simple client (4), as in Apple's virtual-service test. No monitor callback
    // is registered: this component never observes physical keyboard input.
    client = hid.clientCreate(kCFAllocatorDefault, 4, NULL);
    if (!client) return false;
    queue = dispatch_queue_create("rctl.keyboard.hid", DISPATCH_QUEUE_SERIAL);
    properties = [@{@"PrimaryUsagePage": @1, @"PrimaryUsage": @6,
        @"DeviceUsagePairs": @[@{@"DeviceUsagePage": @1, @"DeviceUsage": @6}],
        @"Product": @"rctl remote keyboard", @"Transport": @"Virtual",
        @"VendorID": @0xff00, @"ProductID": @0xff00,
        @"PhysicalDeviceUniqueID": [[NSUUID UUID] UUIDString]} mutableCopy];
    hid.schedule(client, queue);
    dispatch_sync(queue, ^{
        Callbacks callbacks = {notified, setProperty, copyProperty, copyEvent, outputEvent};
        service = hid.serviceCreate(client, NULL, callbacks, NULL, NULL);
    });
    if (!service) { rctl_game_keyboard_stop(); return false; }
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) { rctl_game_keyboard_stop(); return false; }
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                             100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        if (lease.expired(nowMS())) rctl_game_keyboard_stop();
    });
    dispatch_resume(timer);
    return true;
}
}

void rctl_game_keyboard_stop(void) {
    if (timer) { dispatch_source_cancel(timer); timer = nil; }
    if (service) {
        for (auto key : lease.keys) emit(key, false);
        dispatch_sync(queue, ^{ hid.remove(service); CFRelease(service); service = NULL; });
    }
    if (client) {
        dispatch_sync(queue, ^{ hid.unschedule(client, queue); });
        CFRelease(client); client = NULL;
    }
    queue = nil;
    properties = nil;
    lease.clear();
}

NSString *rctl_game_keyboard_request(NSData *request) {
    if (lease.expired(nowMS())) rctl_game_keyboard_stop();
    id object = request.length && request.length <= 2048
        ? [NSJSONSerialization JSONObjectWithData:request options:0 error:nil] : nil;
    if (![object isKindOfClass:[NSDictionary class]]) return failure(@"invalid_keyboard_request");
    NSString *action = object[@"action"], *owner = object[@"owner"];
    if (!rctl_script_string(action, 16) || !rctl_script_string(owner, 32) || owner.length != 32 ||
        [owner rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound)
        return failure(@"invalid_keyboard_request");
    std::string identity(owner.UTF8String);
    if ([action isEqual:@"acquire"]) {
        if (!lease.owner.empty())
            return lease.matches(identity, nowMS()) ? success() : failure(@"keyboard_busy");
        if (!start()) return failure(@"hardware_keyboard_unavailable");
        lease.acquire(identity, nowMS());
        return success();
    }
    if ([action isEqual:@"release"]) {
        if (lease.owner.empty()) return success();
        if (!lease.matches(identity, nowMS())) return failure(@"keyboard_not_owned");
        rctl_game_keyboard_stop();
        return success();
    }
    if (![action isEqual:@"state"]) return failure(@"invalid_keyboard_action");
    id seq = object[@"sequence"];
    NSArray *keys = object[@"keys"];
    if (!rctl_script_number(seq, 1, UINT32_MAX, true) || ![keys isKindOfClass:[NSArray class]] || keys.count > 32)
        return failure(@"invalid_keyboard_state");
    std::set<uint16_t> next;
    for (id key in keys) {
        if (!rctl_script_number(key, 4, 231, true)) return failure(@"invalid_keyboard_usage");
        unsigned usage = [key unsignedIntValue];
        if (usage > 164 && usage < 224) return failure(@"invalid_keyboard_usage");
        if (!next.insert((uint16_t)usage).second) return failure(@"duplicate_keyboard_usage");
    }
    auto previous = lease.keys;
    auto result = lease.replace(identity, [seq unsignedLongLongValue], next, nowMS());
    if (result != rctl::KeyboardLease::Result::OK)
        return failure(result == rctl::KeyboardLease::Result::Stale ? @"stale_keyboard_sequence" : @"keyboard_not_owned");
    bool ok = true;
    // Release removed keys first; press modifiers before ordinary chord keys.
    for (auto key : previous) if (!next.count(key)) ok = emit(key, false) && ok;
    for (int modifiers = 1; modifiers >= 0; modifiers--)
        for (auto key : next) if ((key >= 224) == (bool)modifiers && !previous.count(key)) ok = emit(key, true) && ok;
    if (!ok) { rctl_game_keyboard_stop(); return failure(@"keyboard_dispatch_failed"); }
    return success();
}
