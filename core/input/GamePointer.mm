#import "GamePointer.h"
#include "PointerLease.h"
#include "PointerEvents.h"
#import "ScriptValidation.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <QuartzCore/QuartzCore.h>

namespace {
using Ref = CFTypeRef;
// Apple's legacy virtual-service callback ABI, also used by GameKeyboard.
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
    rctl::PointerEvents pointer;
    Ref (*scroll)(CFAllocatorRef, uint64_t, double, double, double, uint32_t);
} hid;
Ref client, service;
dispatch_queue_t queue;
dispatch_source_t timer;
NSMutableDictionary *properties;
rctl::PointerLease lease;
uint32_t emittedButtons = 0;
uint64_t nowMS() { return (uint64_t)(CACurrentMediaTime() * 1000); }
void notified(void *, void *, Ref, uint32_t, CFDictionaryRef) {}
bool setProperty(void *, void *, Ref, CFStringRef key, Ref value) {
    if (!key || !value) return false;
    properties[(__bridge NSString *)key] = (__bridge id)value; return true;
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
        LOAD(pointer.create, "IOHIDEventCreateRelativePointerEvent");
        LOAD(pointer.children, "IOHIDEventGetChildren");
        LOAD(pointer.type, "IOHIDEventGetType");
        LOAD(pointer.setInteger, "IOHIDEventSetIntegerValue");
        LOAD(scroll, "IOHIDEventCreateScrollEvent");
#undef LOAD
    });
    return hid.clientCreate && hid.schedule && hid.unschedule && hid.serviceCreate && hid.remove && hid.send && hid.pointer.available() && hid.scroll;
}
bool emit(double dx, double dy, uint32_t buttons, double wheel) {
    if (!service) return false;
    __block bool ok = true;
    dispatch_sync(queue, ^{
        Ref event = hid.pointer.mouse(mach_absolute_time(), dx, dy, buttons, emittedButtons);
        ok = event && hid.send(service, event);
        if (ok) emittedButtons = buttons;
        if (event) CFRelease(event);
        if (ok && wheel != 0) {
            event = hid.scroll(kCFAllocatorDefault, mach_absolute_time(), 0, wheel, 0, 0);
            ok = event && hid.send(service, event);
            if (event) CFRelease(event);
        }
    });
    return ok;
}
NSString *json(NSDictionary *value) {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:value options:0 error:nil] encoding:NSUTF8StringEncoding];
}
NSString *failure(NSString *reason) { return json(@{@"error": reason}); }
NSString *success() {
    return json(@{@"ok": @YES, @"active": @(!lease.owner.empty()), @"pointer_version": @1,
                  @"lease_ms": @(rctl::PointerLease::durationMS), @"sequence": @(lease.sequence)});
}
bool start() {
    if (!available()) return false;
    client = hid.clientCreate(kCFAllocatorDefault, 4, NULL);
    if (!client) return false;
    queue = dispatch_queue_create("rctl.pointer.hid", DISPATCH_QUEUE_SERIAL);
    properties = [@{@"PrimaryUsagePage": @1, @"PrimaryUsage": @2,
        @"DeviceUsagePairs": @[@{@"DeviceUsagePage": @1, @"DeviceUsage": @2}],
        @"Product": @"rctl remote mouse", @"Transport": @"Virtual",
        @"VendorID": @0xff00, @"ProductID": @0xff00,
        @"PhysicalDeviceUniqueID": [[NSUUID UUID] UUIDString]} mutableCopy];
    hid.schedule(client, queue);
    dispatch_sync(queue, ^{
        Callbacks callbacks = {notified, setProperty, copyProperty, copyEvent, outputEvent};
        service = hid.serviceCreate(client, NULL, callbacks, NULL, NULL);
    });
    if (!service) { rctl_game_pointer_stop(); return false; }
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) { rctl_game_pointer_stop(); return false; }
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), 100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{ if (lease.expired(nowMS())) rctl_game_pointer_stop(); });
    dispatch_resume(timer);
    return true;
}
}

void rctl_game_pointer_stop(void) {
    if (timer) { dispatch_source_cancel(timer); timer = nil; }
    if (service) {
        if (emittedButtons) emit(0, 0, 0, 0);
        dispatch_sync(queue, ^{ hid.remove(service); CFRelease(service); service = NULL; });
    }
    if (client) {
        dispatch_sync(queue, ^{ hid.unschedule(client, queue); });
        CFRelease(client); client = NULL;
    }
    queue = nil; properties = nil; emittedButtons = 0; lease.clear();
}

NSString *rctl_game_pointer_request(NSData *request) {
    if (lease.expired(nowMS())) rctl_game_pointer_stop();
    id object = request.length && request.length <= 1024 ? [NSJSONSerialization JSONObjectWithData:request options:0 error:nil] : nil;
    if (![object isKindOfClass:[NSDictionary class]]) return failure(@"invalid_pointer_request");
    NSString *action = object[@"action"], *owner = object[@"owner"];
    if (!rctl_script_string(action, 16) || !rctl_script_string(owner, 32) || owner.length != 32 ||
        [owner rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound)
        return failure(@"invalid_pointer_request");
    std::string identity(owner.UTF8String);
    if ([action isEqual:@"acquire"]) {
        if (!lease.owner.empty()) return lease.matches(identity, nowMS()) ? success() : failure(@"pointer_busy");
        if (!start()) return failure(@"hardware_pointer_unavailable");
        lease.acquire(identity, nowMS()); return success();
    }
    if ([action isEqual:@"release"]) {
        if (lease.owner.empty()) return success();
        if (!lease.matches(identity, nowMS())) return failure(@"pointer_not_owned");
        rctl_game_pointer_stop(); return success();
    }
    bool motion = [action isEqual:@"move"];
    if (!motion && ![action isEqual:@"state"]) return failure(@"invalid_pointer_action");
    if (!rctl_script_number(object[@"sequence"], 1, UINT32_MAX, true) ||
        (!motion && !rctl_script_number(object[@"buttons"], 0, 31, true)) ||
        !rctl_script_number(object[@"dx"], -2048, 2048, false) ||
        !rctl_script_number(object[@"dy"], -2048, 2048, false) ||
        !rctl_script_number(object[@"wheel"], -120, 120, false)) return failure(@"invalid_pointer_state");
    if (!lease.matches(identity, nowMS())) return failure(@"pointer_not_owned");
    bool accepted = motion ? lease.move(identity, [object[@"sequence"] unsignedLongLongValue], nowMS())
        : lease.apply(identity, [object[@"sequence"] unsignedLongLongValue], [object[@"buttons"] unsignedIntValue], nowMS());
    if (!accepted)
        return failure(@"stale_pointer_sequence");
    if (!emit([object[@"dx"] doubleValue], [object[@"dy"] doubleValue], lease.buttons, [object[@"wheel"] doubleValue])) {
        rctl_game_pointer_stop(); return failure(@"pointer_dispatch_failed");
    }
    return success();
}
