#include <cassert>
#include <cstdint>
#include <iostream>

#include "privacy/IndicatorState.h"

int main() {
    assert(rctl_mic_indicator_state(false, 4242) == 0);
    assert(rctl_mic_indicator_state(true, 0) == 0);
    assert(rctl_mic_indicator_state(true, 1) == 0);

    uint64_t state = rctl_mic_indicator_state(true, 4242);
    assert(rctl_mic_indicator_pid(state) == 4242);
    assert(rctl_mic_indicator_matches(state, 4242));
    assert(!rctl_mic_indicator_matches(state, 4243));
    assert(!rctl_mic_indicator_matches(0, 4242));

    std::cout << "privacy indicator state test passed\n";
    return 0;
}
