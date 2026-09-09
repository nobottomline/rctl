#include "input/PointerLease.h"
#include <cassert>
#include <cstdio>
int main() {
    using Lease = rctl::PointerLease;
    assert(Lease::requestBudgetMS(true) == 100);
    assert(Lease::requestBudgetMS(false) == 400);
    assert(Lease::requestBudgetMS(false) < Lease::durationMS);
    assert(Lease::requestFresh(1400, 1000));
    assert(Lease::requestFresh(1400, 1399));
    assert(!Lease::requestFresh(1400, 1400));
    assert(!Lease::requestFresh(1400, 1401));
    assert(!Lease::requestFresh(1401, 1000));
    assert(!Lease::requestFresh(0, UINT64_MAX));
    rctl::PointerLease p;
    assert(!p.acquire("", 100));
    assert(p.acquire("a", 100));
    assert(!p.acquire("b", 101));
    assert(!p.apply("b", 1, 1, 110));
    assert(!p.apply("a", 1, 32, 110));
    assert(p.apply("a", 1, 3, 110));
    assert(p.buttons == 3);
    assert(p.move("a", 5, 120));
    assert(!p.move("a", 4, 125));
    assert(!p.move("a", 5, 125));
    assert(!p.move("b", 6, 125));
    assert(!p.move("a", UINT64_MAX, 125));
    assert(p.sequence == 1 && p.buttons == 3 && p.deadline == 1610);
    assert(!p.apply("a", 1, 0, 111));
    assert(!p.apply("a", UINT64_MAX, 0, 111));
    assert(p.acquire("a", 1500));
    assert(p.deadline == 1610); // acquire retries must not retain held buttons
    assert(p.expired(1610));
    assert(!p.apply("a", 2, 0, 1610));
    assert(!p.move("a", 6, 1610));
    p.clear();
    assert(p.buttons == 0 && p.sequence == 0 && p.motionSequence == 0);
    assert(p.acquire("b", 1700));
    assert(!p.apply("a", 2, 0, 1701));
    assert(p.apply("b", 1, 0, 1701));
    puts("Pointer lease tests passed");
}
