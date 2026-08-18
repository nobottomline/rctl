#pragma once

#include <atomic>
#include <stddef.h>
#include <stdint.h>

typedef void (*rctl_virtual_mic_sink)(void *context, uint32_t frame, int16_t sample);

// Stateful, allocation-free resampler for the app's realtime AudioUnit callback.
// The producer owns `write`; the consumer publishes the returned `newRead` only
// after every output sample has been consumed by `sink`.
class RCTLVirtualMicResampler {
public:
    bool render(const std::atomic<int16_t> *ring, size_t capacity,
                uint64_t write, uint64_t read,
                double sourceRate, double targetRate, uint32_t outputFrames,
                uint64_t maxBacklog, uint64_t targetBacklog,
                rctl_virtual_mic_sink sink, void *context, uint64_t *newRead);
    void reset();

private:
    double fraction_ = 0.0;
    uint64_t expectedRead_ = 0;
    bool synchronized_ = false;
};
