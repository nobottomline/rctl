#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <cstdint>

namespace rctl {
struct PointerEvents {
    using Ref = CFTypeRef;
    static constexpr uint32_t buttonType = 2;
    static constexpr uint32_t buttonNumberField = (buttonType << 16) + 1;
    Ref (*create)(CFAllocatorRef, uint64_t, double, double, double, uint32_t, uint32_t, uint32_t) = nullptr;
    CFArrayRef (*children)(Ref) = nullptr;
    uint32_t (*type)(Ref) = nullptr;
    void (*setInteger)(Ref, uint32_t, int) = nullptr;

    bool available() const { return create && children && type && setInteger; }
    Ref mouse(uint64_t timestamp, double dx, double dy, uint32_t buttons, uint32_t previous) const {
        if (!available() || buttons > 31 || previous > 31) return nullptr;
        Ref event = create(kCFAllocatorDefault, timestamp, dx, dy, 0, buttons, previous, 0);
        if (!event) return nullptr;
        uint32_t changed = buttons ^ previous;
        CFArrayRef list = children(event);
        CFIndex count = list ? CFArrayGetCount(list) : 0;
        if (count != __builtin_popcount(changed)) { CFRelease(event); return nullptr; }
        CFIndex childIndex = 0;
        for (unsigned bit = 0; bit < 5; ++bit) {
            if (!(changed & (1u << bit))) continue;
            Ref child = CFArrayGetValueAtIndex(list, childIndex++);
            if (type(child) != buttonType) { CFRelease(event); return nullptr; }
            // Apple's relative-pointer constructor emits transitions in bit order,
            // but some versions label every child as button 1.
            setInteger(child, buttonNumberField, bit + 1);
        }
        return event;
    }
};
}
