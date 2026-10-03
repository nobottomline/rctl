#pragma once

#include <cmath>
#include <cstdint>
#include <map>
#include <set>
#include <utility>

namespace rctl {

// Session-owned held state. The bridge serializes authorization, injection and
// retirement under its mutex. Cleanup never accepts a caller-supplied owner.
struct GuestInputState {
    static constexpr uint32_t homeButton = 1;
    static constexpr uint32_t lockButton = 2;
    static constexpr uint32_t volumeButtons = 4;
    static constexpr uint32_t systemButtons = 8;
    static constexpr uint32_t allButtons = homeButton | lockButton | volumeButtons | systemButtons;
    struct Contact { double x, y; };
    std::map<int, Contact> contacts;
    std::set<std::pair<int, int>> keys;
    bool disabled = false;
    double feedbackAt = 0;
    double budgetAt = 0;
    double tokens = 48;

    // Bound callback/main-queue work independently of signaling rate limits.
    bool admit(double now) {
        if (disabled || !std::isfinite(now)) return false;
        if (budgetAt == 0) budgetAt = now;
        tokens = std::fmin(48.0, tokens + std::fmax(0.0, now - budgetAt) * 240.0);
        budgetAt = now;
        if (tokens < 1) return false;
        tokens -= 1;
        return true;
    }

    bool touch(int phase, int finger, double x, double y) {
        if (disabled || phase < 0 || phase > 2 || finger < 0 || finger > 10 ||
            !std::isfinite(x) || !std::isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1) return false;
        if (phase == 0) {
            if (contacts.count(finger)) return false;
            contacts[finger] = {x, y};
        } else {
            if (!contacts.count(finger)) return false;
            if (phase == 1) contacts[finger] = {x, y};
            else contacts.erase(finger);
        }
        return true;
    }

    bool key(int page, int usage, int down, bool keyboard, bool buttons, uint32_t buttonMask = allButtons) {
        if (disabled || down < 0 || down > 2) return false;
        const bool allowed =
            // Page 7 also contains Power and volume usages. Accept ordinary
            // typing/navigation/function keys and modifiers, not the whole page.
            (keyboard && page == 7 && ((usage >= 4 && usage <= 0x65) ||
                                     (usage >= 0xe0 && usage <= 0xe7))) ||
            (buttons && page == 12 && (
                ((buttonMask & homeButton) && usage == 0x40) ||
                ((buttonMask & lockButton) && usage == 0x30) ||
                ((buttonMask & volumeButtons) && (usage == 0xe9 || usage == 0xea)))) ||
            (buttons && (buttonMask & systemButtons) && page == 0xf0 && (usage == 1 || usage == 2) && down == 2);
        if (!allowed) return false;
        const auto value = std::make_pair(page, usage);
        if (down == 1) {
            if (!keys.insert(value).second) return false;
        } else if (down == 0 && !keys.erase(value)) return false;
        return true;
    }

    template<class Touch, class Key> void release(Touch touch, Key key) {
        disabled = true;
        for (const auto &value : contacts) touch(2, value.first, value.second.x, value.second.y);
        for (const auto &value : keys) key(value.first, value.second, 0);
        contacts.clear();
        keys.clear();
    }
};

} // namespace rctl
