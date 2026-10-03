#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include "net/RetainedState.h"
#include <cassert>
#include <cstdio>
#include <map>
#include <string>
#include <vector>
#include <unistd.h>

static std::atomic<unsigned> destroyed{0}, visited{0};
struct State {
    NSString *owner = @"owned retirement fixture";
    std::atomic<bool> retired{false};
    std::atomic<unsigned> pending{0};
    ~State() { ++destroyed; }
};
using StateRef = rctl::RetainedState<State>;
struct Registry { std::map<std::string, StateRef> states, retiring; };

int main() {
    @autoreleasepool {
        // Assignment, move, empty handles and duplicate retirement must retain
        // one identity and destroy its state exactly once.
        {
            auto state = StateRef::create();
            auto copy = state;
            state = copy;
            auto moved = std::move(copy);
            assert(!copy && state == moved);
            moved = std::move(moved);
            assert(moved == state);
            state.reset();
            assert(destroyed == 0 && moved->owner.length);
        }
        assert(destroyed == 1);
        destroyed = 0;
        dispatch_group_t group = dispatch_group_create();
        constexpr unsigned iterations = 10000;
        for (unsigned i = 0; i < iterations; ++i) {
            @autoreleasepool {
                auto registry = rctl::RetainedState<Registry>::create();
                auto state = StateRef::create();
                registry->states.emplace("guest", state);
                registry->retiring.emplace("guest", state);
                state->retired = true;
                state->pending = 1;
                std::vector<StateRef> closing{state};
                registry->states.clear();
                state.reset();
                dispatch_group_enter(group);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    // Both queue hops outlive their originating stack and
                    // vector. This is the native revoke/IPC-loss ownership path.
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        const auto &owned = closing.front();
                        assert(owned->retired && owned->owner.length && owned->pending == 1);
                        owned->pending = 0;
                        registry->retiring.clear();
                        ++visited;
                        dispatch_group_leave(group);
                    });
                });
                closing.clear();
                registry.reset();
            }
        }
        assert(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0);
        // Dispatch releases a block after its body leaves the group.
        for (unsigned i = 0; i < 1000 && destroyed != iterations; ++i) usleep(1000);
        assert(visited == iterations && destroyed == iterations);
        std::printf("Retirement ownership: %u queue handoffs, %u exact destructions\n",
                    visited.load(), destroyed.load());
    }
}
