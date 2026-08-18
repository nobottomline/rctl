#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <atomic>
#import <cmath>
#import <cerrno>
#import <dlfcn.h>
#import <netinet/in.h>
#import <pthread.h>
#import <substrate.h>
#import <sys/socket.h>
#import <time.h>
#import <unistd.h>

#import "net/VirtualMicServer.h"

static const uint16_t kVirtualMicPort = RCTL_VIRTUAL_MIC_PORT;
static const uint64_t kRingSamples = 48000 * 2;
static std::atomic<int16_t> g_ring[kRingSamples];
static_assert(std::atomic<int16_t>::is_always_lock_free, "virtual mic samples must stay realtime-safe");
static std::atomic<uint64_t> g_write{0};
static std::atomic<uint64_t> g_read{0};
static std::atomic<uint64_t> g_last_render_ms{0};
static std::atomic<uint64_t> g_last_packet_ms{0};
static std::atomic<bool> g_capture_seen{false};
static std::atomic<bool> g_receiver_started{false};

static OSStatus (*g_original_render)(AudioUnit, AudioUnitRenderActionFlags *,
                                    const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);

static uint64_t monotonic_ms(void) {
    timespec now = {};
    clock_gettime(CLOCK_MONOTONIC, &now);
    return static_cast<uint64_t>(now.tv_sec) * 1000 + static_cast<uint64_t>(now.tv_nsec / 1000000);
}

static bool is_input_unit(AudioUnit unit, UInt32 bus) {
    if (bus != 1 || !unit) return false;
    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    AudioComponentDescription description = {};
    if (!component || AudioComponentGetDescription(component, &description) != noErr) return false;
    return description.componentType == kAudioUnitType_Output &&
           (description.componentSubType == kAudioUnitSubType_RemoteIO ||
            description.componentSubType == kAudioUnitSubType_VoiceProcessingIO);
}

static void ring_clear(void) {
    uint64_t write = g_write.load(std::memory_order_acquire);
    g_read.store(write, std::memory_order_release);
    g_last_packet_ms.store(0, std::memory_order_release);
}

static void ring_push(const int16_t *samples, size_t count) {
    if (!samples || !count) return;
    if (count > kRingSamples) { samples += count - kRingSamples; count = kRingSamples; }
    uint64_t write = g_write.load(std::memory_order_relaxed);
    for (size_t i = 0; i < count; i++)
        g_ring[(write + i) % kRingSamples].store(samples[i], std::memory_order_relaxed);
    write += count;
    g_write.store(write, std::memory_order_release);
    uint64_t read = g_read.load(std::memory_order_relaxed);
    if (write - read > kRingSamples) g_read.store(write - kRingSamples, std::memory_order_release);
    g_last_packet_ms.store(monotonic_ms(), std::memory_order_release);
}

// 1=complete, 0=closed/error, -1=receive timeout before any bytes arrived.
static int read_exact(int fd, void *buffer, size_t length) {
    uint8_t *bytes = static_cast<uint8_t *>(buffer);
    bool started = false;
    while (length) {
        ssize_t got = recv(fd, bytes, length, 0);
        if (got <= 0) {
            if (!started && (errno == EAGAIN || errno == EWOULDBLOCK)) return -1;
            return 0;
        }
        started = true;
        bytes += got;
        length -= static_cast<size_t>(got);
    }
    return 1;
}

static void *receiver_main(void *) {
    pthread_setname_np("com.greatlove.rctl.vmic.client");
    for (;;) {
        while (!g_capture_seen.load(std::memory_order_acquire)) usleep(250000);
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) { sleep(1); continue; }
        sockaddr_in address = {};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        address.sin_port = htons(kVirtualMicPort);
        if (connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0) {
            close(fd); sleep(1); continue;
        }
        timeval timeout = {.tv_sec = 1, .tv_usec = 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        ring_clear();
        for (;;) {
            uint32_t networkLength = 0;
            int headerResult = read_exact(fd, &networkLength, sizeof(networkLength));
            if (headerResult < 0) {
                if (monotonic_ms() - g_last_render_ms.load(std::memory_order_acquire) > 10000) {
                    g_capture_seen.store(false, std::memory_order_release);
                    break;
                }
                continue;
            }
            if (headerResult == 0) break;
            uint32_t length = ntohl(networkLength);
            if (!length || length > 5760 * sizeof(int16_t) || (length & 1)) break;
            int16_t samples[5760];
            if (read_exact(fd, samples, length) != 1) break;
            ring_push(samples, length / sizeof(int16_t));
        }
        close(fd);
        ring_clear();
        if (monotonic_ms() - g_last_render_ms.load(std::memory_order_acquire) > 10000)
            g_capture_seen.store(false, std::memory_order_release);
        else
            usleep(500000);
    }
    return nullptr;
}

static void write_sample(AudioBufferList *io, const AudioStreamBasicDescription &format,
                         UInt32 frame, int16_t sample) {
    bool nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 channels = MAX(1u, format.mChannelsPerFrame);
    if (format.mFormatFlags & kAudioFormatFlagIsFloat) {
        float value = static_cast<float>(sample) / 32768.0f;
        if (nonInterleaved) {
            for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
                if (io->mBuffers[b].mData && io->mBuffers[b].mDataByteSize >= (frame + 1) * sizeof(float))
                    static_cast<float *>(io->mBuffers[b].mData)[frame] = value;
            }
        } else if (io->mNumberBuffers && io->mBuffers[0].mData &&
                   io->mBuffers[0].mDataByteSize >= (frame + 1) * channels * sizeof(float)) {
            float *out = static_cast<float *>(io->mBuffers[0].mData) + frame * channels;
            for (UInt32 channel = 0; channel < channels; channel++) out[channel] = value;
        }
    } else if ((format.mFormatFlags & kAudioFormatFlagIsSignedInteger) && format.mBitsPerChannel == 16) {
        if (nonInterleaved) {
            for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
                if (io->mBuffers[b].mData && io->mBuffers[b].mDataByteSize >= (frame + 1) * sizeof(int16_t))
                    static_cast<int16_t *>(io->mBuffers[b].mData)[frame] = sample;
            }
        } else if (io->mNumberBuffers && io->mBuffers[0].mData &&
                   io->mBuffers[0].mDataByteSize >= (frame + 1) * channels * sizeof(int16_t)) {
            int16_t *out = static_cast<int16_t *>(io->mBuffers[0].mData) + frame * channels;
            for (UInt32 channel = 0; channel < channels; channel++) out[channel] = sample;
        }
    } else if ((format.mFormatFlags & kAudioFormatFlagIsSignedInteger) && format.mBitsPerChannel == 32) {
        UInt32 fractionBits = (format.mFormatFlags & kLinearPCMFormatFlagsSampleFractionMask) >>
                              kLinearPCMFormatFlagsSampleFractionShift;
        if (!fractionBits) fractionBits = 31;
        fractionBits = MIN(fractionBits, 31u);
        int32_t value = fractionBits >= 15
            ? static_cast<int32_t>(static_cast<int64_t>(sample) * (1LL << (fractionBits - 15)))
            : static_cast<int32_t>(sample) / (1 << (15 - fractionBits));
        if (nonInterleaved) {
            for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
                if (io->mBuffers[b].mData && io->mBuffers[b].mDataByteSize >= (frame + 1) * sizeof(int32_t))
                    static_cast<int32_t *>(io->mBuffers[b].mData)[frame] = value;
            }
        } else if (io->mNumberBuffers && io->mBuffers[0].mData &&
                   io->mBuffers[0].mDataByteSize >= (frame + 1) * channels * sizeof(int32_t)) {
            int32_t *out = static_cast<int32_t *>(io->mBuffers[0].mData) + frame * channels;
            for (UInt32 channel = 0; channel < channels; channel++) out[channel] = value;
        }
    }
}

static void replace_input(AudioUnit unit, UInt32 bus, UInt32 frames, AudioBufferList *io) {
    if (!io || !io->mNumberBuffers || !frames) return;
    AudioStreamBasicDescription format = {};
    UInt32 size = sizeof(format);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                             bus, &format, &size) != noErr || format.mSampleRate < 8000) return;
    if (format.mFormatID != kAudioFormatLinearPCM) return;
    bool supported = ((format.mFormatFlags & kAudioFormatFlagIsFloat) && format.mBitsPerChannel == 32) ||
                     ((format.mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
                      (format.mBitsPerChannel == 16 || format.mBitsPerChannel == 32));
    if (!supported || monotonic_ms() - g_last_packet_ms.load(std::memory_order_acquire) > 600) return;

    double ratio = 48000.0 / format.mSampleRate;
    uint64_t write = g_write.load(std::memory_order_acquire);
    uint64_t read = g_read.load(std::memory_order_relaxed);
    uint64_t available = write - read;
    uint64_t needed = static_cast<uint64_t>(ceil(static_cast<double>(frames) * ratio)) + 2;
    if (available > 4800) { read = write - 2880; available = write - read; } // cap latency near 60 ms
    if (available < needed) return; // preserve the real microphone on underflow

    static thread_local double fraction = 0.0;
    for (UInt32 frame = 0; frame < frames; frame++) {
        double source = fraction + static_cast<double>(frame) * ratio;
        uint64_t base = static_cast<uint64_t>(source);
        double part = source - static_cast<double>(base);
        int16_t a = g_ring[(read + base) % kRingSamples].load(std::memory_order_relaxed);
        int16_t b = g_ring[(read + base + 1) % kRingSamples].load(std::memory_order_relaxed);
        int16_t sample = static_cast<int16_t>(static_cast<double>(a) + (static_cast<double>(b) - a) * part);
        write_sample(io, format, frame, sample);
    }
    double consumed = fraction + static_cast<double>(frames) * ratio;
    uint64_t whole = static_cast<uint64_t>(consumed);
    fraction = consumed - static_cast<double>(whole);
    g_read.store(read + whole, std::memory_order_release);
}

static OSStatus hooked_render(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                              const AudioTimeStamp *timestamp, UInt32 bus, UInt32 frames,
                              AudioBufferList *io) {
    OSStatus status = g_original_render(unit, flags, timestamp, bus, frames, io);
    if (status != noErr || !is_input_unit(unit, bus)) return status;
    g_last_render_ms.store(monotonic_ms(), std::memory_order_release);
    g_capture_seen.store(true, std::memory_order_release);
    bool expected = false;
    if (g_receiver_started.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
        pthread_t receiver;
        if (pthread_create(&receiver, nullptr, receiver_main, nullptr) == 0) pthread_detach(receiver);
        else g_receiver_started.store(false, std::memory_order_release);
    }
    replace_input(unit, bus, frames, io);
    return status;
}

__attribute__((constructor)) static void install_virtual_mic(void) {
    if ([[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) return;
    void *symbol = dlsym(RTLD_DEFAULT, "AudioUnitRender");
    if (symbol) MSHookFunction(symbol, reinterpret_cast<void *>(hooked_render),
                               reinterpret_cast<void **>(&g_original_render));
}
