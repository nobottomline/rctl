#pragma once
#include <cstdint>
#include <set>
#include <string>

namespace rctl {
// Monotonic milliseconds; all access is serialized by the SpringBoard owner.
class KeyboardLease {
public:
    static constexpr uint64_t durationMS = 1500;
    enum class Result { OK, Busy, Missing, Stale };
    std::string owner;
    std::set<uint16_t> keys;
    uint64_t sequence = 0;
    uint64_t deadline = 0;

    bool expired(uint64_t now) const { return !owner.empty() && now >= deadline; }
    bool matches(const std::string &id, uint64_t now) const {
        return !id.empty() && owner == id && !expired(now);
    }
    Result acquire(const std::string &id, uint64_t now) {
        if (id.empty()) return Result::Missing;
        if (!owner.empty()) return matches(id, now) ? Result::OK : Result::Busy;
        owner = id;
        sequence = 0;
        deadline = now + durationMS;
        return Result::OK;
    }
    Result replace(const std::string &id, uint64_t seq, const std::set<uint16_t> &next, uint64_t now) {
        if (!matches(id, now)) return Result::Missing;
        if (seq <= sequence) return Result::Stale;
        sequence = seq;
        keys = next;
        deadline = now + durationMS;
        return Result::OK;
    }
    void clear() { owner.clear(); keys.clear(); sequence = deadline = 0; }
};
}
