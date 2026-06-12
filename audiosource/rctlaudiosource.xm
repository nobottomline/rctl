// rctlaudiosource — safe mediaserverd audio-source skeleton.
//
// No hooks and no render-path modification. When explicitly loaded with the
// marker file present, sends a short synthetic PCM stream to rctld's audio
// ingest socket. The future real tap should reuse this send path.

#import <Foundation/Foundation.h>
#import <pthread.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <time.h>
#import <errno.h>
#import <string.h>
#import <math.h>
#import "ipc/Ipc.h"

#define RCTL_AUDIO_SOURCE_LOG "/tmp/rctl-audiosource.log"
#define RCTL_AUDIO_SOURCE_MARKER "/tmp/rctl-audiosource-tone"
#define RCTL_AUDIO_SOURCE_RATE 48000
#define RCTL_AUDIO_SOURCE_FRAMES 960

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

static bool send_pcm_packet(int fd, uint64_t pts_us,
                            const int16_t *samples, uint16_t frames) {
    uint8_t payload[16 + RCTL_AUDIO_SOURCE_FRAMES * 2];
    put_be64(payload, pts_us);
    put_be32(payload + 8, RCTL_AUDIO_SOURCE_RATE);
    payload[12] = 1;
    payload[13] = 2;
    put_be16(payload + 14, frames);
    for (uint16_t i = 0; i < frames; i++) put_le16(payload + 16 + i * 2, samples[i]);
    return send_audio_frame(fd, payload, 16 + frames * 2);
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
        if (!send_pcm_packet(fd, (uint64_t)n * 20000, samples, RCTL_AUDIO_SOURCE_FRAMES)) break;
        sent++;
        usleep(20000);
    }
    close(fd);

    char line[96];
    snprintf(line, sizeof(line), "tone thread done packets=%d", sent);
    as_log(line);
    return NULL;
}

%ctor {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"?";
        if (![proc isEqualToString:@"mediaserverd"]) return;

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
