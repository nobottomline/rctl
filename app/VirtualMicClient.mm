#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <atomic>
#import <cerrno>
#import <cstring>
#import <netinet/in.h>
#import <new>
#import <pthread.h>
#import <sys/socket.h>
#import <time.h>
#import <unistd.h>

#import "net/VirtualMicServer.h"
#import "audio/VirtualMicDSP.h"
#import "VirtualMicClient.h"

static const uint16_t kVirtualMicPort = RCTL_VIRTUAL_MIC_PORT;
static const uint64_t kRingSamples = 48000 * 2;
// Allocate only after the process filter has rejected SpringBoard. A namespace-
// scope array of 96,000 C++ atomics runs initialization before any constructor
// guard and can prevent later Substitute payloads from loading in SpringBoard.
static std::atomic<int16_t> *g_ring = nullptr;
static_assert(std::atomic<int16_t>::is_always_lock_free, "virtual mic samples must stay realtime-safe");
static std::atomic<uint64_t> g_write{0};
static std::atomic<uint64_t> g_read{0};
static std::atomic<uint64_t> g_last_render_ms{0};
static std::atomic<uint64_t> g_last_packet_ms{0};
static std::atomic<bool> g_capture_seen{false};
static std::atomic<AudioUnit> g_pending_unit{nullptr};
static std::atomic<AudioUnit> g_configured_unit{nullptr};
static std::atomic<uint64_t> g_format_rate{0};
static std::atomic<uint32_t> g_format_flags{0};
static std::atomic<uint32_t> g_format_bits{0};
static std::atomic<uint32_t> g_format_channels{0};

static uint64_t monotonic_ms(void) {
    timespec now = {};
    clock_gettime(CLOCK_MONOTONIC, &now);
    return static_cast<uint64_t>(now.tv_sec) * 1000 + static_cast<uint64_t>(now.tv_nsec / 1000000);
}

static bool read_input_format(AudioUnit unit, AudioStreamBasicDescription *format) {
    if (!unit || !format) return false;
    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    AudioComponentDescription description = {};
    if (!component || AudioComponentGetDescription(component, &description) != noErr) return false;
    if (description.componentType != kAudioUnitType_Output ||
        (description.componentSubType != kAudioUnitSubType_RemoteIO &&
         description.componentSubType != kAudioUnitSubType_VoiceProcessingIO)) return false;
    UInt32 size = sizeof(*format);
    return AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                                1, format, &size) == noErr &&
           format->mFormatID == kAudioFormatLinearPCM && format->mSampleRate >= 8000;
}

static void publish_format(AudioUnit unit, const AudioStreamBasicDescription &format) {
    uint64_t rate = 0;
    static_assert(sizeof(rate) == sizeof(format.mSampleRate), "sample rate storage must match");
    memcpy(&rate, &format.mSampleRate, sizeof(rate));
    g_format_rate.store(rate, std::memory_order_relaxed);
    g_format_flags.store(format.mFormatFlags, std::memory_order_relaxed);
    g_format_bits.store(format.mBitsPerChannel, std::memory_order_relaxed);
    g_format_channels.store(format.mChannelsPerFrame, std::memory_order_relaxed);
    g_configured_unit.store(unit, std::memory_order_release);
}

static bool load_format(AudioUnit unit, AudioStreamBasicDescription *format) {
    if (!format || g_configured_unit.load(std::memory_order_acquire) != unit) return false;
    uint64_t rate = g_format_rate.load(std::memory_order_relaxed);
    memcpy(&format->mSampleRate, &rate, sizeof(rate));
    format->mFormatID = kAudioFormatLinearPCM;
    format->mFormatFlags = g_format_flags.load(std::memory_order_relaxed);
    format->mBitsPerChannel = g_format_bits.load(std::memory_order_relaxed);
    format->mChannelsPerFrame = g_format_channels.load(std::memory_order_relaxed);
    return true;
}

static void *format_main(void *) {
    pthread_setname_np("com.greatlove.rctl.vmic.format");
    for (;;) {
        AudioUnit pending = g_pending_unit.load(std::memory_order_acquire);
        if (!pending || pending == g_configured_unit.load(std::memory_order_acquire)) {
            usleep(20000);
            continue;
        }
        AudioStreamBasicDescription format = {};
        if (read_input_format(pending, &format)) publish_format(pending, format);
        else usleep(100000);
    }
    return nullptr;
}

static void ring_clear(void) {
    uint64_t write = g_write.load(std::memory_order_acquire);
    g_read.store(write, std::memory_order_release);
    g_last_packet_ms.store(0, std::memory_order_release);
}

static void ring_push(const int16_t *samples, size_t count) {
    if (!g_ring || !samples || !count) return;
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
    bool firstConnection = true;
    for (;;) {
        if (!firstConnection)
            while (!g_capture_seen.load(std::memory_order_acquire)) usleep(250000);
        firstConnection = false;
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
                uint64_t lastRender = g_last_render_ms.load(std::memory_order_acquire);
                if (lastRender && monotonic_ms() - lastRender > 10000) {
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
        uint64_t lastRender = g_last_render_ms.load(std::memory_order_acquire);
        if (lastRender && monotonic_ms() - lastRender > 10000)
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

struct RenderContext {
    AudioBufferList *buffers;
    const AudioStreamBasicDescription *format;
};

static void render_sample(void *rawContext, uint32_t frame, int16_t sample) {
    RenderContext *context = static_cast<RenderContext *>(rawContext);
    write_sample(context->buffers, *context->format, frame, sample);
}

static void replace_input(const AudioStreamBasicDescription &format, UInt32 frames,
                          AudioBufferList *io) {
    if (!io || !io->mNumberBuffers || !frames) return;
    bool supported = ((format.mFormatFlags & kAudioFormatFlagIsFloat) && format.mBitsPerChannel == 32) ||
                     ((format.mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
                      (format.mBitsPerChannel == 16 || format.mBitsPerChannel == 32));
    if (!supported || monotonic_ms() - g_last_packet_ms.load(std::memory_order_acquire) > 600) return;

    uint64_t write = g_write.load(std::memory_order_acquire);
    uint64_t read = g_read.load(std::memory_order_relaxed);
    uint64_t newRead = read;
    RenderContext context = {io, &format};
    static thread_local RCTLVirtualMicResampler resampler;
    if (!resampler.render(g_ring, kRingSamples, write, read, 48000.0, format.mSampleRate,
                          frames, 4800, 2880, render_sample, &context, &newRead)) return;
    g_read.store(newRead, std::memory_order_release);
}

static bool infer_format(AudioBufferList *buffers, UInt32 frames,
                         AudioStreamBasicDescription *format) {
    if (!buffers || !buffers->mNumberBuffers || !frames || !format) return false;
    const AudioBuffer &first = buffers->mBuffers[0];
    UInt32 channels = MAX(1u, first.mNumberChannels);
    uint64_t samples = static_cast<uint64_t>(frames) * channels;
    if (!first.mData || !samples || first.mDataByteSize % samples) return false;
    UInt32 bytesPerSample = first.mDataByteSize / samples;
    if (bytesPerSample != sizeof(float) && bytesPerSample != sizeof(int16_t)) return false;
    for (UInt32 i = 1; i < buffers->mNumberBuffers; i++) {
        const AudioBuffer &buffer = buffers->mBuffers[i];
        UInt32 bufferChannels = MAX(1u, buffer.mNumberChannels);
        uint64_t bufferSamples = static_cast<uint64_t>(frames) * bufferChannels;
        if (!buffer.mData || !bufferSamples ||
            buffer.mDataByteSize != bufferSamples * bytesPerSample) return false;
    }
    format->mSampleRate = 48000.0;
    format->mFormatID = kAudioFormatLinearPCM;
    format->mFormatFlags = kAudioFormatFlagIsPacked |
        (bytesPerSample == sizeof(float) ? kAudioFormatFlagIsFloat
                                         : kAudioFormatFlagIsSignedInteger);
    if (buffers->mNumberBuffers > 1) format->mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
    format->mBitsPerChannel = bytesPerSample * 8;
    format->mChannelsPerFrame = buffers->mNumberBuffers > 1 ? 1 : channels;
    return true;
}

OSStatus rctl_virtual_mic_process(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                                  const AudioTimeStamp *timestamp, UInt32 bus, UInt32 frames,
                                  AudioBufferList *io, OSStatus status) {
    (void)flags;
    (void)timestamp;
    if (status != noErr || !g_ring || !unit || bus != 1) return status;
    g_last_render_ms.store(monotonic_ms(), std::memory_order_release);
    g_capture_seen.store(true, std::memory_order_release);
    g_pending_unit.store(unit, std::memory_order_release);
    AudioStreamBasicDescription format = {};
    if (!load_format(unit, &format) && !infer_format(io, frames, &format)) return status;
    replace_input(format, frames, io);
    return status;
}

extern "C" void rctl_virtual_mic_activate(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_ring = new (std::nothrow) std::atomic<int16_t>[kRingSamples]();
        if (!g_ring) return;
        pthread_t receiver;
        if (pthread_create(&receiver, nullptr, receiver_main, nullptr) == 0)
            pthread_detach(receiver);
        pthread_t format;
        if (pthread_create(&format, nullptr, format_main, nullptr) == 0)
            pthread_detach(format);
    });
}
