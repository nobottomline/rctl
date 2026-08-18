#include "audio/VirtualMicDSP.h"

#include <array>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <vector>

static void collect(void *context, uint32_t frame, int16_t sample) {
    auto *samples = static_cast<std::vector<int16_t> *>(context);
    assert(frame == samples->size());
    samples->push_back(sample);
}

int main() {
    std::array<std::atomic<int16_t>, 12000> ring;
    for (size_t i = 0; i < ring.size(); i++) ring[i].store(static_cast<int16_t>(i));

    RCTLVirtualMicResampler identity;
    std::vector<int16_t> output;
    uint64_t read = 0;
    assert(identity.render(ring.data(), ring.size(), 100, read, 48000, 48000, 4,
                           4800, 2880, collect, &output, &read));
    assert((output == std::vector<int16_t>{0, 1, 2, 3}));
    assert(read == 4);

    output.clear();
    assert(identity.render(ring.data(), ring.size(), 100, read, 48000, 48000, 3,
                           4800, 2880, collect, &output, &read));
    assert((output == std::vector<int16_t>{4, 5, 6}));
    assert(read == 7);

    RCTLVirtualMicResampler downsample;
    output.clear();
    read = 0;
    assert(downsample.render(ring.data(), ring.size(), 100, read, 48000, 24000, 4,
                             4800, 2880, collect, &output, &read));
    assert((output == std::vector<int16_t>{0, 2, 4, 6}));
    assert(read == 8);

    std::array<std::atomic<int16_t>, 16> ramp;
    for (size_t i = 0; i < ramp.size(); i++) ramp[i].store(static_cast<int16_t>(i * 100));
    RCTLVirtualMicResampler upsample;
    output.clear();
    read = 0;
    assert(upsample.render(ramp.data(), ramp.size(), 16, read, 48000, 96000, 4,
                           0, 0, collect, &output, &read));
    assert((output == std::vector<int16_t>{0, 50, 100, 150}));
    assert(read == 2);

    RCTLVirtualMicResampler underflow;
    output.clear();
    read = 10;
    assert(!underflow.render(ring.data(), ring.size(), 14, read, 48000, 48000, 4,
                             4800, 2880, collect, &output, &read));
    assert(output.empty());
    assert(read == 10);

    RCTLVirtualMicResampler latencyDrop;
    output.clear();
    read = 0;
    assert(latencyDrop.render(ring.data(), ring.size(), 10000, read, 48000, 48000, 2,
                              4800, 2880, collect, &output, &read));
    assert((output == std::vector<int16_t>{7120, 7121}));
    assert(read == 7122);

    // An external ring clear/overflow changes read unexpectedly. The resampler
    // must reset its fractional phase before consuming the new discontinuity.
    RCTLVirtualMicResampler discontinuity;
    output.clear();
    read = 0;
    assert(discontinuity.render(ring.data(), ring.size(), 100, read, 48000, 44100, 1,
                                4800, 2880, collect, &output, &read));
    read = 50;
    output.clear();
    assert(discontinuity.render(ring.data(), ring.size(), 100, read, 48000, 44100, 1,
                                4800, 2880, collect, &output, &read));
    assert(output.front() == 50);

    printf("virtual mic DSP test passed\n");
    return 0;
}
