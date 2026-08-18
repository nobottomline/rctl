#include "audio/VirtualMicDSP.h"

bool RCTLVirtualMicResampler::render(const std::atomic<int16_t> *ring, size_t capacity,
                                     uint64_t write, uint64_t read,
                                     double sourceRate, double targetRate, uint32_t outputFrames,
                                     uint64_t maxBacklog, uint64_t targetBacklog,
                                     rctl_virtual_mic_sink sink, void *context, uint64_t *newRead) {
    if (!ring || capacity < 2 || write < read || sourceRate <= 0 || targetRate <= 0 ||
        !outputFrames || !sink || !newRead) return false;

    if (synchronized_ && read != expectedRead_) fraction_ = 0.0;
    uint64_t available = write - read;
    if (maxBacklog && available > maxBacklog) {
        uint64_t retained = targetBacklog < available ? targetBacklog : available;
        read = write - retained;
        available = retained;
        fraction_ = 0.0;
    }

    double ratio = sourceRate / targetRate;
    double lastSource = fraction_ + static_cast<double>(outputFrames - 1) * ratio;
    uint64_t needed = static_cast<uint64_t>(lastSource) + 2;
    if (available < needed) {
        expectedRead_ = read;
        synchronized_ = true;
        *newRead = read;
        return false;
    }

    for (uint32_t frame = 0; frame < outputFrames; frame++) {
        double source = fraction_ + static_cast<double>(frame) * ratio;
        uint64_t base = static_cast<uint64_t>(source);
        double part = source - static_cast<double>(base);
        int16_t a = ring[(read + base) % capacity].load(std::memory_order_relaxed);
        int16_t b = ring[(read + base + 1) % capacity].load(std::memory_order_relaxed);
        int16_t sample = static_cast<int16_t>(static_cast<double>(a) +
                                             (static_cast<double>(b) - a) * part);
        sink(context, frame, sample);
    }

    double consumed = fraction_ + static_cast<double>(outputFrames) * ratio;
    uint64_t whole = static_cast<uint64_t>(consumed);
    fraction_ = consumed - static_cast<double>(whole);
    *newRead = read + whole;
    expectedRead_ = *newRead;
    synchronized_ = true;
    return true;
}

void RCTLVirtualMicResampler::reset() {
    fraction_ = 0.0;
    expectedRead_ = 0;
    synchronized_ = false;
}
