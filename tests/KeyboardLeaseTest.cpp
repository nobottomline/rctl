#include "input/KeyboardLease.h"
#include <cassert>
#include <cstdio>

int main() {
    using Lease = rctl::KeyboardLease;
    using R = Lease::Result;
    Lease lease;
    assert(lease.acquire("", 0) == R::Missing);
    assert(lease.acquire("a", 100) == R::OK);
    assert(lease.acquire("b", 101) == R::Busy);
    assert(lease.replace("b", 1, {26}, 102) == R::Missing);
    assert(lease.replace("a", 1, {26, 225}, 200) == R::OK);
    assert(lease.keys == std::set<uint16_t>({26, 225}));
    assert(lease.replace("a", 1, {}, 250) == R::Stale);
    assert(lease.replace("a", 0, {}, 250) == R::Stale);
    assert(lease.deadline == 1700);
    assert(lease.acquire("a", 300) == R::OK);
    assert(lease.deadline == 1700); // acquisition retries cannot hold keys forever
    assert(!lease.expired(1699));
    assert(lease.expired(1700));
    assert(lease.replace("a", 2, {26}, 1700) == R::Missing);
    lease.clear(); // runtime releases events and destroys the virtual service
    assert(lease.keys.empty());
    assert(lease.acquire("b", 1800) == R::OK);
    assert(lease.replace("a", 99, {26}, 1801) == R::Missing);
    assert(lease.replace("b", 1, {4, 26}, 1900) == R::OK);
    assert(lease.replace("b", 2, {}, 2000) == R::OK);
    assert(lease.keys.empty());
    assert(lease.sequence == 2);
    assert(lease.replace("b", 1, {26}, 2001) == R::Stale);
    puts("Keyboard lease tests passed");
}
