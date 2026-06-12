// rctlaudiosource — safe mediaserverd audio-source skeleton.
//
// No hooks and no render-path modification. When explicitly loaded with the
// marker file present, sends a short synthetic PCM stream to rctld's audio
// ingest socket. The future real tap should reuse this send path.

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <pthread.h>
#import <substrate.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <time.h>
#import <errno.h>
#import <string.h>
#import <math.h>
#import <dlfcn.h>
#import "ipc/Ipc.h"

#define RCTL_AUDIO_SOURCE_LOG "/tmp/rctl-audiosource.log"
#define RCTL_AUDIO_SOURCE_MARKER "/tmp/rctl-audiosource-tone"
#define RCTL_AUDIO_CAPTURE_MARKER "/tmp/rctl-audiosource-capture"
#define RCTL_AUDIO_SOURCE_RATE 48000
#define RCTL_AUDIO_SOURCE_FRAMES 960
#define RCTL_CAPTURE_MAX_QUEUE 64
#define RCTL_CAPTURE_TTL_SEC 180

static FILE *as_log_open(void) {
    return fopen(RCTL_AUDIO_SOURCE_LOG, "a");
}

static void as_log(const char *msg) {
    FILE *f = as_log_open();
    if (!f) return;
    fprintf(f, "[%ld pid=%d] %s\n", (long)time(NULL), getpid(), msg);
    fclose(f);
}

static void put_be64(uint8_t *p, uint64_t v) {
    p[0] = (v >> 56) & 0xff; p[1] = (v >> 48) & 0xff;
    p[2] = (v >> 40) & 0xff; p[3] = (v >> 32) & 0xff;
    p[4] = (v >> 24) & 0xff; p[5] = (v >> 16) & 0xff;
    p[6] = (v >> 8) & 0xff;  p[7] = v & 0xff;
}

static void put_be32(uint8_t *p, uint32_t v) {
    p[0] = (v >> 24) & 0xff; p[1] = (v >> 16) & 0xff;
    p[2] = (v >> 8) & 0xff;  p[3] = v & 0xff;
}

static void put_be16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}

static void put_le16(uint8_t *p, int16_t v) {
    p[0] = (uint8_t)(v & 0xff);
    p[1] = (uint8_t)(((uint16_t)v >> 8) & 0xff);
}

static bool write_all(int fd, const void *buf, size_t n) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t off = 0;
    while (off < n) {
        ssize_t k = write(fd, p + off, n - off);
        if (k <= 0) { if (k < 0 && errno == EINTR) continue; return false; }
        off += (size_t)k;
    }
    return true;
}

static int connect_unix_audio(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un a; memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, RCTL_AUDIO_IPC_SOCK_PATH, sizeof(a.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0) {
        as_log("connected via unix audio socket");
        return fd;
    }
    char line[128];
    snprintf(line, sizeof(line), "unix audio socket connect failed errno=%d %s", errno, strerror(errno));
    as_log(line);
    close(fd);
    return -1;
}

static int connect_tcp_audio(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in a; memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(RCTL_AUDIO_TCP_PORT);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0) {
        as_log("connected via tcp audio socket");
        return fd;
    }
    char line[128];
    snprintf(line, sizeof(line), "tcp audio socket connect failed errno=%d %s", errno, strerror(errno));
    as_log(line);
    close(fd);
    return -1;
}

static bool send_audio_frame(int fd, const uint8_t *payload, uint32_t len) {
    uint8_t hdr[5];
    hdr[0] = RCTL_MSG_AUDIO;
    hdr[1] = (uint8_t)(len >> 24);
    hdr[2] = (uint8_t)(len >> 16);
    hdr[3] = (uint8_t)(len >> 8);
    hdr[4] = (uint8_t)len;
    return write_all(fd, hdr, sizeof(hdr)) && write_all(fd, payload, len);
}

static bool send_pcm_packet(int fd, uint64_t pts_us, uint32_t rate, uint8_t channels,
                            const int16_t *samples, uint16_t frames) {
    if (channels == 0 || channels > 2 || frames == 0) return false;
    uint8_t payload[16 + 4096 * 2 * 2];
    size_t sample_count = (size_t)frames * channels;
    if (frames > 4096) return false;
    put_be64(payload, pts_us);
    put_be32(payload + 8, rate);
    payload[12] = channels;
    payload[13] = 2;
    put_be16(payload + 14, frames);
    for (size_t i = 0; i < sample_count; i++) put_le16(payload + 16 + i * 2, samples[i]);
    return send_audio_frame(fd, payload, (uint32_t)(16 + sample_count * 2));
}

static void *tone_thread(void *arg) {
    as_log("tone thread starting");
    int fd = connect_unix_audio();
    for (int i = 0; i < 30 && fd < 0; i++) {
        fd = connect_tcp_audio();
        if (fd < 0) usleep(100000);
    }
    if (fd < 0) {
        as_log("audio socket connect failed on all transports");
        return NULL;
    }
    usleep(2000000); // allow an external /stream test reader to be active after mediaserverd restart

    int16_t samples[RCTL_AUDIO_SOURCE_FRAMES];
    double phase = 0.0;
    int sent = 0;
    for (int n = 0; n < 150; n++) {
        for (int i = 0; i < RCTL_AUDIO_SOURCE_FRAMES; i++) {
            samples[i] = (int16_t)(sin(phase * 2.0 * M_PI) * 4200.0);
            phase += 440.0 / (double)RCTL_AUDIO_SOURCE_RATE;
            if (phase >= 1.0) phase -= 1.0;
        }
        if (!send_pcm_packet(fd, (uint64_t)n * 20000, RCTL_AUDIO_SOURCE_RATE, 1,
                             samples, RCTL_AUDIO_SOURCE_FRAMES)) break;
        sent++;
        usleep(20000);
    }
    close(fd);

    char line[96];
    snprintf(line, sizeof(line), "tone thread done packets=%d", sent);
    as_log(line);
    return NULL;
}

typedef struct capture_packet {
    struct capture_packet *next;
    uint64_t pts_us;
    uint32_t rate;
    uint8_t channels;
    uint16_t frames;
    int16_t *samples;
} capture_packet;

static pthread_mutex_t gCaptureLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gCaptureCond = PTHREAD_COND_INITIALIZER;
static capture_packet *gCaptureHead = NULL;
static capture_packet *gCaptureTail = NULL;
static int gCaptureQueued = 0;
static uint64_t gCapturePtsUs = 0;
static bool gCaptureEnabled = false;
static bool gCaptureWorkerStarted = false;
static time_t gCaptureDeadline = 0;
static int gCaptureLoggedFormats = 0;
static int gCaptureDropped = 0;
static OSStatus (*orig_AudioQueueEnqueueBuffer)(AudioQueueRef, AudioQueueBufferRef,
                                                UInt32, const AudioStreamPacketDescription *) = NULL;
static OSStatus (*orig_AudioQueueEnqueueBufferWithParameters)(AudioQueueRef, AudioQueueBufferRef,
                                                              UInt32, const AudioStreamPacketDescription *,
                                                              UInt32, UInt32, UInt32,
                                                              const AudioQueueParameterEvent *,
                                                              const AudioTimeStamp *, AudioTimeStamp *) = NULL;
static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *, UInt32, UInt32,
                                        AudioBufferList *) = NULL;

static void enqueue_capture_packet(capture_packet *pkt) {
    pthread_mutex_lock(&gCaptureLock);
    if (gCaptureQueued >= RCTL_CAPTURE_MAX_QUEUE) {
        gCaptureDropped++;
        pthread_mutex_unlock(&gCaptureLock);
        free(pkt->samples);
        free(pkt);
        return;
    }
    if (gCaptureTail) gCaptureTail->next = pkt;
    else gCaptureHead = pkt;
    gCaptureTail = pkt;
    gCaptureQueued++;
    pthread_cond_signal(&gCaptureCond);
    pthread_mutex_unlock(&gCaptureLock);
}

static capture_packet *dequeue_capture_packet(void) {
    pthread_mutex_lock(&gCaptureLock);
    while (!gCaptureHead && gCaptureEnabled) pthread_cond_wait(&gCaptureCond, &gCaptureLock);
    if (!gCaptureHead) {
        pthread_mutex_unlock(&gCaptureLock);
        return NULL;
    }
    capture_packet *pkt = gCaptureHead;
    gCaptureHead = pkt->next;
    if (!gCaptureHead) gCaptureTail = NULL;
    gCaptureQueued--;
    pthread_mutex_unlock(&gCaptureLock);
    pkt->next = NULL;
    return pkt;
}

static void *capture_worker(void *arg) {
    as_log("capture worker starting");
    int fd = -1;
    while (fd < 0) {
        fd = connect_tcp_audio();
        if (fd < 0) usleep(250000);
    }
    int sent = 0;
    for (;;) {
        capture_packet *pkt = dequeue_capture_packet();
        if (!pkt) break;
        if (fd < 0 || !send_pcm_packet(fd, pkt->pts_us, pkt->rate, pkt->channels,
                                       pkt->samples, pkt->frames)) {
            if (fd >= 0) close(fd);
            fd = -1;
            while (fd < 0) {
                fd = connect_tcp_audio();
                if (fd < 0) usleep(250000);
            }
            (void)send_pcm_packet(fd, pkt->pts_us, pkt->rate, pkt->channels,
                                  pkt->samples, pkt->frames);
        }
        sent++;
        if ((sent % 250) == 0) {
            char line[128];
            snprintf(line, sizeof(line), "capture packets sent=%d dropped=%d", sent, gCaptureDropped);
            as_log(line);
        }
        free(pkt->samples);
        free(pkt);
    }
    if (fd >= 0) close(fd);
    char line[128];
    snprintf(line, sizeof(line), "capture worker stopped sent=%d dropped=%d", sent, gCaptureDropped);
    as_log(line);
    return NULL;
}

static void *capture_watchdog(void *arg) {
    sleep(RCTL_CAPTURE_TTL_SEC);
    pthread_mutex_lock(&gCaptureLock);
    if (gCaptureEnabled) {
        gCaptureEnabled = false;
        pthread_cond_signal(&gCaptureCond);
    }
    pthread_mutex_unlock(&gCaptureLock);
    as_log("capture watchdog expired; disabled capture");
    return NULL;
}

static bool capture_format_supported(const AudioStreamBasicDescription *asbd) {
    if (asbd->mFormatID != kAudioFormatLinearPCM) return false;
    if (asbd->mChannelsPerFrame < 1 || asbd->mChannelsPerFrame > 2) return false;
    if (asbd->mSampleRate < 8000 || asbd->mSampleRate > 192000) return false;
    if (asbd->mBytesPerFrame == 0) return false;
    if (asbd->mFormatFlags & kAudioFormatFlagIsBigEndian) return false;
    if (asbd->mBitsPerChannel == 16 && (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger)) return true;
    if (asbd->mBitsPerChannel == 32 && (asbd->mFormatFlags & kAudioFormatFlagIsFloat)) return true;
    return false;
}

static void log_skipped_format(const char *source, const AudioStreamBasicDescription *asbd) {
    if (gCaptureLoggedFormats >= 20) return;
    char line[224];
    snprintf(line, sizeof(line), "skip %s fmt id=0x%08x flags=0x%08x rate=%.0f ch=%u bits=%u bpf=%u",
             source, (unsigned)asbd->mFormatID, (unsigned)asbd->mFormatFlags, asbd->mSampleRate,
             (unsigned)asbd->mChannelsPerFrame, (unsigned)asbd->mBitsPerChannel,
             (unsigned)asbd->mBytesPerFrame);
    as_log(line);
    gCaptureLoggedFormats++;
}

static void enqueue_interleaved_samples(const AudioStreamBasicDescription *asbd,
                                        const void *data, uint32_t byte_size) {
    if (!gCaptureEnabled || !data || byte_size == 0) return;
    if (gCaptureDeadline && time(NULL) >= gCaptureDeadline) {
        gCaptureEnabled = false;
        pthread_cond_signal(&gCaptureCond);
        as_log("capture TTL expired; disabling capture");
        return;
    }
    if (!capture_format_supported(asbd)) {
        log_skipped_format("pcm", asbd);
        return;
    }

    uint32_t channels = asbd->mChannelsPerFrame;
    uint32_t bytes_per_frame = asbd->mBytesPerFrame;
    uint32_t frames_total = byte_size / bytes_per_frame;
    if (frames_total == 0) return;
    uint32_t frames = frames_total > 4096 ? 4096 : frames_total;
    size_t sample_count = (size_t)frames * channels;
    int16_t *samples = (int16_t *)malloc(sample_count * sizeof(int16_t));
    if (!samples) return;

    const uint8_t *src = (const uint8_t *)data;
    if (asbd->mBitsPerChannel == 16) {
        memcpy(samples, src, sample_count * sizeof(int16_t));
    } else {
        const float *f = (const float *)src;
        for (size_t i = 0; i < sample_count; i++) {
            float v = f[i];
            if (v > 1.0f) v = 1.0f;
            else if (v < -1.0f) v = -1.0f;
            samples[i] = (int16_t)(v * 32767.0f);
        }
    }

    capture_packet *pkt = (capture_packet *)calloc(1, sizeof(*pkt));
    if (!pkt) { free(samples); return; }
    pkt->rate = (uint32_t)(asbd->mSampleRate + 0.5);
    pkt->channels = (uint8_t)channels;
    pkt->frames = (uint16_t)frames;
    pkt->samples = samples;

    pthread_mutex_lock(&gCaptureLock);
    pkt->pts_us = gCapturePtsUs;
    gCapturePtsUs += (uint64_t)((double)frames * 1000000.0 / asbd->mSampleRate);
    pthread_mutex_unlock(&gCaptureLock);

    enqueue_capture_packet(pkt);
}

static void maybe_capture_audioqueue(AudioQueueRef aq, AudioQueueBufferRef buffer) {
    if (!gCaptureEnabled || !aq || !buffer || !buffer->mAudioData || buffer->mAudioDataByteSize == 0) return;

    AudioStreamBasicDescription asbd;
    UInt32 sz = sizeof(asbd);
    if (AudioQueueGetProperty(aq, kAudioQueueProperty_StreamDescription, &asbd, &sz) != noErr) return;
    if (sz < sizeof(asbd) || !capture_format_supported(&asbd)) {
        if (gCaptureLoggedFormats < 12) {
            log_skipped_format("aq", &asbd);
        }
        return;
    }
    enqueue_interleaved_samples(&asbd, buffer->mAudioData, buffer->mAudioDataByteSize);
}

static void maybe_capture_audiounit(AudioUnit unit, UInt32 bus, UInt32 frames, AudioBufferList *ioData) {
    if (!gCaptureEnabled || !unit || !ioData || frames == 0) return;
    AudioStreamBasicDescription asbd;
    UInt32 sz = sizeof(asbd);
    OSStatus st = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, bus, &asbd, &sz);
    if (st != noErr || sz < sizeof(asbd)) {
        st = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input, bus, &asbd, &sz);
        if (st != noErr || sz < sizeof(asbd)) return;
    }

    if (ioData->mNumberBuffers == 1) {
        AudioBuffer *b = &ioData->mBuffers[0];
        enqueue_interleaved_samples(&asbd, b->mData, b->mDataByteSize);
        return;
    }

    if (!capture_format_supported(&asbd) || asbd.mChannelsPerFrame != ioData->mNumberBuffers) {
        log_skipped_format("au", &asbd);
        return;
    }

    uint32_t channels = ioData->mNumberBuffers;
    uint32_t frames_avail = frames > 4096 ? 4096 : frames;
    int16_t *samples = (int16_t *)malloc((size_t)frames_avail * channels * sizeof(int16_t));
    if (!samples) return;

    for (uint32_t c = 0; c < channels; c++) {
        AudioBuffer *b = &ioData->mBuffers[c];
        if (!b->mData || b->mDataByteSize == 0) { free(samples); return; }
        if (asbd.mBitsPerChannel == 16) {
            const int16_t *src = (const int16_t *)b->mData;
            for (uint32_t i = 0; i < frames_avail; i++) samples[i * channels + c] = src[i];
        } else {
            const float *src = (const float *)b->mData;
            for (uint32_t i = 0; i < frames_avail; i++) {
                float v = src[i];
                if (v > 1.0f) v = 1.0f;
                else if (v < -1.0f) v = -1.0f;
                samples[i * channels + c] = (int16_t)(v * 32767.0f);
            }
        }
    }

    AudioStreamBasicDescription interleaved = asbd;
    interleaved.mChannelsPerFrame = channels;
    interleaved.mBytesPerFrame = channels * 2;
    interleaved.mBitsPerChannel = 16;
    interleaved.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    enqueue_interleaved_samples(&interleaved, samples, frames_avail * channels * sizeof(int16_t));
    free(samples);
}

static OSStatus hook_AudioQueueEnqueueBuffer(AudioQueueRef inAQ, AudioQueueBufferRef inBuffer,
                                             UInt32 inNumPacketDescs,
                                             const AudioStreamPacketDescription *inPacketDescs) {
    maybe_capture_audioqueue(inAQ, inBuffer);
    return orig_AudioQueueEnqueueBuffer(inAQ, inBuffer, inNumPacketDescs, inPacketDescs);
}

static OSStatus hook_AudioQueueEnqueueBufferWithParameters(AudioQueueRef inAQ, AudioQueueBufferRef inBuffer,
                                                           UInt32 inNumPacketDescs,
                                                           const AudioStreamPacketDescription *inPacketDescs,
                                                           UInt32 inTrimFramesAtStart,
                                                           UInt32 inTrimFramesAtEnd,
                                                           UInt32 inNumParamValues,
                                                           const AudioQueueParameterEvent *inParamValues,
                                                           const AudioTimeStamp *inStartTime,
                                                           AudioTimeStamp *outActualStartTime) {
    maybe_capture_audioqueue(inAQ, inBuffer);
    return orig_AudioQueueEnqueueBufferWithParameters(inAQ, inBuffer, inNumPacketDescs, inPacketDescs,
                                                      inTrimFramesAtStart, inTrimFramesAtEnd,
                                                      inNumParamValues, inParamValues,
                                                      inStartTime, outActualStartTime);
}

static OSStatus hook_AudioUnitRender(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags,
                                     const AudioTimeStamp *inTimeStamp, UInt32 inOutputBusNumber,
                                     UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus st = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber,
                                       inNumberFrames, ioData);
    if (st == noErr) maybe_capture_audiounit(inUnit, inOutputBusNumber, inNumberFrames, ioData);
    return st;
}

static void start_capture_hook(void) {
    if (gCaptureWorkerStarted) return;
    gCaptureEnabled = true;
    gCaptureDeadline = time(NULL) + RCTL_CAPTURE_TTL_SEC;
    pthread_t t;
    if (pthread_create(&t, NULL, capture_worker, NULL) == 0) {
        pthread_detach(t);
        gCaptureWorkerStarted = true;
    } else {
        as_log("capture worker create failed");
        gCaptureEnabled = false;
        return;
    }
    pthread_t wt;
    if (pthread_create(&wt, NULL, capture_watchdog, NULL) == 0) pthread_detach(wt);

    char line[96];
    snprintf(line, sizeof(line), "capture enabled ttl=%ds", RCTL_CAPTURE_TTL_SEC);
    as_log(line);

    void *sym = dlsym(RTLD_DEFAULT, "AudioQueueEnqueueBuffer");
    if (sym) {
        MSHookFunction(sym, (void *)hook_AudioQueueEnqueueBuffer, (void **)&orig_AudioQueueEnqueueBuffer);
        as_log("AudioQueueEnqueueBuffer hook installed");
    } else {
        as_log("AudioQueueEnqueueBuffer symbol missing");
    }

    sym = dlsym(RTLD_DEFAULT, "AudioQueueEnqueueBufferWithParameters");
    if (sym) {
        MSHookFunction(sym, (void *)hook_AudioQueueEnqueueBufferWithParameters,
                       (void **)&orig_AudioQueueEnqueueBufferWithParameters);
        as_log("AudioQueueEnqueueBufferWithParameters hook installed");
    } else {
        as_log("AudioQueueEnqueueBufferWithParameters symbol missing");
    }

    sym = dlsym(RTLD_DEFAULT, "AudioUnitRender");
    if (sym) {
        MSHookFunction(sym, (void *)hook_AudioUnitRender, (void **)&orig_AudioUnitRender);
        as_log("AudioUnitRender hook installed");
    } else {
        as_log("AudioUnitRender symbol missing");
    }
}

%ctor {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"?";
        if (![proc isEqualToString:@"mediaserverd"]) return;

        if (access(RCTL_AUDIO_CAPTURE_MARKER, F_OK) == 0) {
            as_log("loaded with capture marker; installing hook");
            start_capture_hook();
            return;
        }

        if (access(RCTL_AUDIO_SOURCE_MARKER, F_OK) != 0) {
            as_log("loaded without marker; idle");
            return;
        }

        as_log("loaded with marker; starting tone thread");
        pthread_t t;
        if (pthread_create(&t, NULL, tone_thread, NULL) == 0) pthread_detach(t);
        else as_log("tone thread create failed");
    }
}
