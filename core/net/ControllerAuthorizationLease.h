#pragma once

#include <cstdint>
#include <string>
#include <utility>

namespace rctl {

// Called under the bridge mutex. Times use a device-local, sleep-inclusive clock.
// A reply extends from challenge issuance, never from reply arrival; a queued
// pre-revocation reply therefore cannot resurrect or indefinitely renew access.
struct ControllerAuthorizationLease {
    static constexpr double lifetime = 20.0;
    static constexpr double renewalInterval = 5.0;
    int64_t revision;
    double expiresAt;
    double issuedAt;
    std::string nonce;
    bool confirmed = false;
    bool retired = false;

    ControllerAuthorizationLease(int64_t revision, double now)
        : revision(revision), expiresAt(now + lifetime), issuedAt(now) {}

    bool expired(double now) const { return retired || now >= expiresAt; }
    bool authorized(double now) const { return confirmed && !expired(now); }
    bool challengeDue(double now) const {
        return !expired(now) && nonce.empty() && (!confirmed || now >= issuedAt + renewalInterval);
    }
    void challenge(std::string value, double now) { nonce = std::move(value); issuedAt = now; }
    bool renew(int64_t grantedRevision, const std::string &reply, double now) {
        if (expired(now) || nonce.empty() || reply != nonce || grantedRevision != revision || now >= issuedAt + lifetime) return false;
        expiresAt = issuedAt + lifetime;
        nonce.clear();
        confirmed = true;
        return true;
    }
};

} // namespace rctl
