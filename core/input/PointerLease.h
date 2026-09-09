#pragma once
#include <cstdint>
#include <chrono>
#include <string>

namespace rctl {
class PointerLease {
public:
    static constexpr uint64_t durationMS = 1500;
    static constexpr uint64_t requestBudgetMS(bool motion) { return motion ? 100 : 400; }
    static bool requestFresh(uint64_t deadline, uint64_t now) {
        return deadline > now && deadline - now <= requestBudgetMS(false);
    }
    static uint64_t clockMS() {
        return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
    }
    std::string owner;
    uint64_t sequence = 0, motionSequence = 0, deadline = 0;
    uint32_t buttons = 0;
    bool expired(uint64_t now) const { return !owner.empty() && now >= deadline; }
    bool matches(const std::string &id, uint64_t now) const {
        return !id.empty() && owner == id && !expired(now);
    }
    bool acquire(const std::string &id, uint64_t now) {
        if (id.empty()) return false;
        if (!owner.empty()) return matches(id, now);
        owner = id; sequence = motionSequence = buttons = 0; deadline = now + durationMS;
        return true;
    }
    bool apply(const std::string &id, uint64_t seq, uint32_t mask, uint64_t now) {
        if (!matches(id, now) || seq <= sequence || seq > UINT32_MAX || mask > 31) return false;
        sequence = seq; buttons = mask; deadline = now + durationMS;
        return true;
    }
    bool move(const std::string &id, uint64_t seq, uint64_t now) {
        if (!matches(id, now) || seq <= motionSequence || seq > UINT32_MAX) return false;
        motionSequence = seq; return true;
    }
    void clear() { owner.clear(); sequence = motionSequence = deadline = buttons = 0; }
};
}
