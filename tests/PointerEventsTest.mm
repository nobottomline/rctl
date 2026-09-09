#include "input/PointerEvents.h"
#include <cassert>
#include <cstdio>
#include <dlfcn.h>
#include <mach/mach_time.h>

int main() {
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    rctl::PointerEvents api;
#define LOAD(member, symbol) api.member = (decltype(api.member))dlsym(RTLD_DEFAULT, symbol)
    LOAD(create, "IOHIDEventCreateRelativePointerEvent");
    LOAD(children, "IOHIDEventGetChildren");
    LOAD(type, "IOHIDEventGetType");
    LOAD(setInteger, "IOHIDEventSetIntegerValue");
#undef LOAD
    auto get = (int (*)(CFTypeRef, uint32_t))dlsym(RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
    assert(api.available() && get);
    // Construct only: never create a service or dispatch input in host tests.
    for (uint32_t previous = 0; previous < 32; ++previous) {
        for (uint32_t buttons = 0; buttons < 32; ++buttons) {
            CFTypeRef event = api.mouse(mach_absolute_time(), 2, -3, buttons, previous);
            assert(event);
            CFArrayRef list = api.children(event);
            CFIndex count = list ? CFArrayGetCount(list) : 0;
            assert(count == __builtin_popcount(buttons ^ previous));
            CFIndex index = 0;
            for (unsigned bit = 0; bit < 5; ++bit) {
                if (!((buttons ^ previous) & (1u << bit))) continue;
                CFTypeRef child = CFArrayGetValueAtIndex(list, index++);
                assert(api.type(child) == api.buttonType);
                assert(get(child, api.buttonNumberField) == (int)bit + 1);
                assert(get(child, api.buttonType << 16) == (int)buttons);
                // Button pressure (field +3) is 1 on press, 0 on release.
                assert(get(child, (api.buttonType << 16) + 3) == !!(buttons & (1u << bit)));
            }
            CFRelease(event);
        }
    }
    assert(!api.mouse(0, 0, 0, 32, 0));
    api.create = nullptr;
    assert(!api.mouse(0, 0, 0, 0, 0));
    puts("Pointer HID event tests passed (1024 button transitions)");
}
