// rctld — root daemon, supervised by launchd (RunAtLoad + KeepAlive).
// Hosts the transport (HTTP/WebCodecs today; WebSocket/REST/WebRTC next) and
// relays between browsers and the SpringBoard agent over a local Unix socket:
//   SB -> daemon: encoded H.264 access units + orientation
//   daemon -> SB: touch / key / reconfigure commands
// A second local socket accepts timestamped PCM packets from future audio
// capture sources (for example a mediaserverd tap) without joining the SB
// command channel.
// Keeping transport here means a network bug can't respring SpringBoard, and
// launchd restarts us on any crash.

#import <Foundation/Foundation.h>
#import <pthread.h>
#import <unistd.h>
#import <stdio.h>
#import <stdarg.h>
#import <string.h>
#import <time.h>
#import <dlfcn.h>
#import <spawn.h>
#import <dirent.h>
#import <sys/stat.h>
#import <sys/socket.h>
#import <sys/wait.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <errno.h>
#import <notify.h>
#import <fcntl.h>
#import "net/HttpStreamServer.h"
#import "ipc/Ipc.h"

extern char **environ;

#define RCTL_AUDIO_PAYLOAD_DYLIB "/usr/local/lib/rctl/audio/rctlaudio.dylib"
#define RCTL_AUDIO_PAYLOAD_PLIST "/usr/local/lib/rctl/audio/rctlaudio.plist"
#define RCTL_AUDIO_ACTIVE_DYLIB "/Library/MobileSubstrate/DynamicLibraries/rctlaudio.dylib"
#define RCTL_AUDIO_ACTIVE_PLIST "/Library/MobileSubstrate/DynamicLibraries/rctlaudio.plist"
#define RCTL_AUDIO_CAPTURE_MARKER "/tmp/rctl-audio-capture"
#define RCTL_AUDIO_TONE_MARKER "/tmp/rctl-audio-tone"
#define RCTL_AUDIO_LOG "/tmp/rctl-audio.log"
#define RCTL_AUDIO_LEGACY_ACTIVE_DYLIB "/Library/MobileSubstrate/DynamicLibraries/rctlaudiosource.dylib"
#define RCTL_AUDIO_LEGACY_ACTIVE_PLIST "/Library/MobileSubstrate/DynamicLibraries/rctlaudiosource.plist"
#define RCTL_AUDIO_LEGACY_CAPTURE_MARKER "/tmp/rctl-audiosource-capture"
#define RCTL_AUDIO_LEGACY_TONE_MARKER "/tmp/rctl-audiosource-tone"
#define RCTL_RELAY_CONFIG_PLIST "/var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist"

typedef struct {
    bool enabled;
    char relay_url[512];
    char enroll_token[256];
    char device_name[128];
} rctl_relay_config;

static void respring_device(void) {
    pid_t pid;
    char *argv[] = { (char *)"killall", (char *)"SpringBoard", NULL };
    posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, argv, environ);
}

static void dlog(const char *msg) {
    FILE *f = fopen("/tmp/rctld.log", "a");
    if (f) { fprintf(f, "[%ld pid=%d] %s\n", (long)time(NULL), getpid(), msg); fclose(f); }
}

static void dlogf(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    dlog(buf);
}

static void copy_nsstring(char *dst, size_t dst_len, id value) {
    if (!dst || dst_len == 0) return;
    dst[0] = 0;
    if (![value isKindOfClass:[NSString class]]) return;
    const char *s = [(NSString *)value UTF8String];
    if (!s) return;
    strlcpy(dst, s, dst_len);
}

static rctl_relay_config load_relay_config(void) {
    rctl_relay_config cfg;
    memset(&cfg, 0, sizeof(cfg));

    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:@RCTL_RELAY_CONFIG_PLIST];
    if (![dict isKindOfClass:[NSDictionary class]]) {
        dlog("relay disabled: config plist missing");
        return cfg;
    }

    id enabled = dict[@"Enabled"];
    cfg.enabled = [enabled respondsToSelector:@selector(boolValue)] && [enabled boolValue];
    copy_nsstring(cfg.relay_url, sizeof(cfg.relay_url), dict[@"RelayURL"]);
    copy_nsstring(cfg.enroll_token, sizeof(cfg.enroll_token), dict[@"EnrollToken"]);
    copy_nsstring(cfg.device_name, sizeof(cfg.device_name), dict[@"DeviceName"]);

    if (!cfg.enabled) {
        dlog("relay disabled: Enabled=false");
        return cfg;
    }
    if (strncmp(cfg.relay_url, "wss://", 6) != 0) {
        dlog("relay disabled: RelayURL must start with wss://");
        cfg.enabled = false;
        return cfg;
    }
    if (strlen(cfg.enroll_token) < 32) {
        dlog("relay disabled: EnrollToken is missing or too short");
        cfg.enabled = false;
        return cfg;
    }

    dlogf("relay configured: url set, token length=%zu, device name %s",
          strlen(cfg.enroll_token), cfg.device_name[0] ? "set" : "unset");
    return cfg;
}

static uint64_t read_be64(const uint8_t *p) {
    return ((uint64_t)p[0] << 56) | ((uint64_t)p[1] << 48) |
           ((uint64_t)p[2] << 40) | ((uint64_t)p[3] << 32) |
           ((uint64_t)p[4] << 24) | ((uint64_t)p[5] << 16) |
           ((uint64_t)p[6] << 8)  | (uint64_t)p[7];
}
static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  |  (uint32_t)p[3];
}
static uint16_t read_be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}
static int16_t read_le16s(const uint8_t *p) {
    uint16_t u = (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
    return (int16_t)u;
}

static rctl_http_server *gHttp = NULL;
static rctl_ipc        *gSB    = NULL;                       // current SB connection
static pthread_mutex_t  gSBLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t  gAudioCtlLock = PTHREAD_MUTEX_INITIALIZER;
static bool             gAudioCaptureDesired = false;
static pthread_mutex_t  gAudioOutputLock = PTHREAD_MUTEX_INITIALIZER;
static bool             gDeviceAudioEnabled = true;
static double           gSavedDeviceVolume = 0.5;

// Forward an HTTP-side command to the SpringBoard agent (drops if SB is away).
static void send_to_sb(uint8_t type, const void *data, uint32_t len) {
    pthread_mutex_lock(&gSBLock);
    if (gSB) (void)rctl_ipc_send(gSB, type, data, len);
    pthread_mutex_unlock(&gSBLock);
}

// ---- request/response: send a query to SB and block for its reply ----
#define RCTL_MAX_PENDING 16
typedef struct { uint32_t reqid; dispatch_semaphore_t sem; char *result; bool used; } pending_t;
static pending_t gPending[RCTL_MAX_PENDING];
static pthread_mutex_t gPendLock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t gNextReqid = 1;

// Deliver a REPLY from SB to the waiting query (called from the ipc thread).
static void deliver_reply(uint32_t reqid, const uint8_t *payload, uint32_t len) {
    pthread_mutex_lock(&gPendLock);
    for (int i = 0; i < RCTL_MAX_PENDING; i++) {
        if (gPending[i].used && gPending[i].reqid == reqid && !gPending[i].result) {
            gPending[i].result = (char *)malloc(len + 1);
            if (gPending[i].result) { memcpy(gPending[i].result, payload, len); gPending[i].result[len] = 0; }
            dispatch_semaphore_signal(gPending[i].sem);
            break;
        }
    }
    pthread_mutex_unlock(&gPendLock);
}

// Send a query to SB and wait up to `timeout` s for the reply. Returns a malloc'd
// string (caller frees) or NULL on timeout/no-SB.
static char *sb_query(uint8_t qtype, const char *payload, uint32_t plen, double timeout) {
    pthread_mutex_lock(&gPendLock);
    int slot = -1;
    for (int i = 0; i < RCTL_MAX_PENDING; i++) if (!gPending[i].used) { slot = i; break; }
    if (slot < 0) { pthread_mutex_unlock(&gPendLock); return NULL; }
    uint32_t reqid = gNextReqid++;
    gPending[slot].used = true; gPending[slot].reqid = reqid;
    gPending[slot].sem = dispatch_semaphore_create(0); gPending[slot].result = NULL;
    pthread_mutex_unlock(&gPendLock);

    uint32_t blen = 5 + plen;
    uint8_t *buf = (uint8_t *)malloc(blen);
    buf[0] = reqid >> 24; buf[1] = reqid >> 16; buf[2] = reqid >> 8; buf[3] = (uint8_t)reqid; buf[4] = qtype;
    if (plen) memcpy(buf + 5, payload, plen);
    send_to_sb(RCTL_MSG_QUERY, buf, blen);
    free(buf);

    long timedout = dispatch_semaphore_wait(gPending[slot].sem,
                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    pthread_mutex_lock(&gPendLock);
    char *result = timedout == 0 ? gPending[slot].result : NULL;
    if (timedout != 0 && gPending[slot].result) free(gPending[slot].result);
    gPending[slot].used = false; gPending[slot].result = NULL; gPending[slot].sem = NULL;
    pthread_mutex_unlock(&gPendLock);
    return result;
}

static void on_input(void *ctx, int phase, int finger, double nx, double ny) {
    rctl_ipc_input m = { (int32_t)phase, (int32_t)finger, nx, ny };
    send_to_sb(RCTL_MSG_INPUT, &m, sizeof m);
}

static void on_key(void *ctx, int page, int usage, int down) {
    rctl_ipc_key m = { (int32_t)page, (int32_t)usage, (int32_t)down };
    send_to_sb(RCTL_MSG_KEY, &m, sizeof m);
}

static void on_reconfigure(void *ctx, int fps, double scale, int bitrate) {
    rctl_ipc_config m = { (int32_t)fps, scale, (int32_t)bitrate };
    send_to_sb(RCTL_MSG_CONFIG, &m, sizeof m);
    rctl_http_signal_reset(gHttp);   // stream resolution/SPS will change
}

// ---- REST automation plane (/v1/*) --------------------------------------
// High-level actions (tap/swipe/type/button/launch/script) usable from curl or
// any script, distinct from the realtime input channel. All timed sequences are
// scheduled on a serial queue so the HTTP thread returns immediately.

static dispatch_queue_t gAuto;
#define AFTER(secs, blk) \
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((secs) * NSEC_PER_SEC)), gAuto, (blk))

static void ipc_input(int phase, double x, double y) {
    rctl_ipc_input m = { (int32_t)phase, 0, x, y }; send_to_sb(RCTL_MSG_INPUT, &m, sizeof m);
}
static void ipc_key(int page, int usage, int down) {
    rctl_ipc_key m = { (int32_t)page, (int32_t)usage, (int32_t)down }; send_to_sb(RCTL_MSG_KEY, &m, sizeof m);
}

static bool audio_capture_set(bool on, char *err, size_t errsz);

// ---- Idle/active session gating (battery saver) -------------------------------
// The capture+encode pipeline and the keep-awake idle-timer resets live in
// SpringBoard and cost real battery (the display never sleeps). Run them ONLY
// while a browser is actually watching: tell SB to wake when the first /stream
// client connects, and to idle (let the device sleep) when the last one leaves.
static int gSessionGen = 0;                     // bumped per transition (serialized on gAuto)
static void send_active(bool on) {
    uint8_t b = on ? 1 : 0;
    send_to_sb(RCTL_MSG_ACTIVE, &b, 1);
    dlog(on ? "session ACTIVE -> SB" : "session IDLE -> SB");
}
static void on_session(void *ctx, bool active) {
    // Serialize on gAuto; debounce idle by a few seconds so a page refresh or a
    // brief Wi-Fi blip doesn't thrash the capture session off and back on.
    dispatch_async(gAuto, ^{
        int gen = ++gSessionGen;
        if (active) send_active(true);
        else AFTER(4.0, ^{
            if (gen == gSessionGen) {
                send_active(false);
                audio_capture_set(false, NULL, 0);
            }
        });
    });
}

static bool file_exists(const char *path) {
    return access(path, F_OK) == 0;
}

static bool copy_file(const char *src, const char *dst, mode_t mode) {
    int in = open(src, O_RDONLY);
    if (in < 0) return false;
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, mode);
    if (out < 0) { close(in); return false; }
    uint8_t buf[65536];
    bool ok = true;
    for (;;) {
        ssize_t r = read(in, buf, sizeof(buf));
        if (r == 0) break;
        if (r < 0) { if (errno == EINTR) continue; ok = false; break; }
        uint8_t *p = buf;
        ssize_t left = r;
        while (left > 0) {
            ssize_t w = write(out, p, (size_t)left);
            if (w < 0) { if (errno == EINTR) continue; ok = false; left = 0; break; }
            p += w;
            left -= w;
        }
        if (!ok) break;
    }
    close(out);
    close(in);
    chmod(dst, mode);
    return ok;
}

static int run_wait(const char *path, char *const argv[]) {
    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, NULL, NULL, argv, environ);
    if (rc != 0) return -rc;
    int st = 0;
    while (waitpid(pid, &st, 0) < 0) {
        if (errno != EINTR) return -errno;
    }
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static void restart_mediaserverd(void) {
    char *argv[] = { (char *)"killall", (char *)"mediaserverd", NULL };
    (void)run_wait("/usr/bin/killall", argv);
}

static bool pause_video_for_media_restart(void) {
    bool resume = gHttp && rctl_http_has_clients(gHttp);
    if (resume) {
        send_active(false);
        usleep(350000);
    }
    return resume;
}

static void resume_video_after_media_restart(bool resume) {
    if (!resume) return;
    usleep(800000);
    rctl_http_signal_reset(gHttp);
    send_active(true);
}

static bool touch_file(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT, 0644);
    if (fd < 0) return false;
    close(fd);
    return true;
}

static void set_err(char *err, size_t errsz, const char *msg) {
    if (err && errsz > 0) snprintf(err, errsz, "%s", msg);
}

static bool audio_capture_set(bool on, char *err, size_t errsz) {
    pthread_mutex_lock(&gAudioCtlLock);
    bool ok = true;
    if (on) {
        if (!file_exists(RCTL_AUDIO_PAYLOAD_DYLIB) || !file_exists(RCTL_AUDIO_PAYLOAD_PLIST)) {
            set_err(err, errsz, "audio payload missing");
            ok = false;
        } else {
            unlink(RCTL_AUDIO_TONE_MARKER);
            unlink(RCTL_AUDIO_CAPTURE_MARKER);
            unlink(RCTL_AUDIO_ACTIVE_DYLIB);
            unlink(RCTL_AUDIO_ACTIVE_PLIST);
            unlink(RCTL_AUDIO_LEGACY_TONE_MARKER);
            unlink(RCTL_AUDIO_LEGACY_CAPTURE_MARKER);
            unlink(RCTL_AUDIO_LEGACY_ACTIVE_DYLIB);
            unlink(RCTL_AUDIO_LEGACY_ACTIVE_PLIST);
            if (!copy_file(RCTL_AUDIO_PAYLOAD_DYLIB, RCTL_AUDIO_ACTIVE_DYLIB, 0755) ||
                !copy_file(RCTL_AUDIO_PAYLOAD_PLIST, RCTL_AUDIO_ACTIVE_PLIST, 0644)) {
                set_err(err, errsz, "copy audio payload failed");
                ok = false;
            } else {
                char *ldid_argv[] = { (char *)"ldid", (char *)"-S", (char *)RCTL_AUDIO_ACTIVE_DYLIB, NULL };
                (void)run_wait("/usr/bin/ldid", ldid_argv);
                if (!touch_file(RCTL_AUDIO_CAPTURE_MARKER)) {
                    set_err(err, errsz, "capture marker failed");
                    ok = false;
                } else {
                    unlink(RCTL_AUDIO_LOG);
                    bool resumeVideo = pause_video_for_media_restart();
                    restart_mediaserverd();
                    resume_video_after_media_restart(resumeVideo);
                    gAudioCaptureDesired = true;
                    dlog("audio capture enabled");
                }
            }
        }
    } else {
        bool hadActive = file_exists(RCTL_AUDIO_ACTIVE_DYLIB) || file_exists(RCTL_AUDIO_ACTIVE_PLIST) ||
                         file_exists(RCTL_AUDIO_CAPTURE_MARKER) || file_exists(RCTL_AUDIO_TONE_MARKER) ||
                         file_exists(RCTL_AUDIO_LEGACY_ACTIVE_DYLIB) || file_exists(RCTL_AUDIO_LEGACY_ACTIVE_PLIST) ||
                         file_exists(RCTL_AUDIO_LEGACY_CAPTURE_MARKER) || file_exists(RCTL_AUDIO_LEGACY_TONE_MARKER);
        unlink(RCTL_AUDIO_ACTIVE_DYLIB);
        unlink(RCTL_AUDIO_ACTIVE_PLIST);
        unlink(RCTL_AUDIO_CAPTURE_MARKER);
        unlink(RCTL_AUDIO_TONE_MARKER);
        unlink(RCTL_AUDIO_LEGACY_ACTIVE_DYLIB);
        unlink(RCTL_AUDIO_LEGACY_ACTIVE_PLIST);
        unlink(RCTL_AUDIO_LEGACY_CAPTURE_MARKER);
        unlink(RCTL_AUDIO_LEGACY_TONE_MARKER);
        if (gAudioCaptureDesired || hadActive) {
            bool resumeVideo = pause_video_for_media_restart();
            restart_mediaserverd();
            resume_video_after_media_restart(resumeVideo);
        }
        gAudioCaptureDesired = false;
        dlog("audio capture disabled");
    }
    pthread_mutex_unlock(&gAudioCtlLock);
    return ok;
}

static char *audio_capture_status_json(void) {
    bool payload = file_exists(RCTL_AUDIO_PAYLOAD_DYLIB) && file_exists(RCTL_AUDIO_PAYLOAD_PLIST);
    bool active = file_exists(RCTL_AUDIO_ACTIVE_DYLIB) && file_exists(RCTL_AUDIO_ACTIVE_PLIST);
    bool marker = file_exists(RCTL_AUDIO_CAPTURE_MARKER);
    bool desired = false;
    pthread_mutex_lock(&gAudioCtlLock);
    desired = gAudioCaptureDesired;
    pthread_mutex_unlock(&gAudioCtlLock);
    char body[256];
    snprintf(body, sizeof(body),
             "{\"ok\":true,\"payload\":%s,\"active\":%s,\"marker\":%s,\"desired\":%s}",
             payload ? "true" : "false",
             active ? "true" : "false",
             marker ? "true" : "false",
             desired ? "true" : "false");
    return strdup(body);
}

static void handle_audio_packet(const uint8_t *buf, uint32_t len) {
    if (len < 16) return;
    uint64_t pts_us = read_be64(buf);
    uint32_t sample_rate = read_be32(buf + 8);
    uint8_t channels = buf[12];
    uint8_t bytes_per_sample = buf[13];
    uint16_t frames = read_be16(buf + 14);
    if (sample_rate == 0 || bytes_per_sample != 2 || channels == 0 || channels > 2 || frames == 0) return;
    size_t sample_count = (size_t)frames * (size_t)channels;
    size_t pcm_len = sample_count * 2;
    if (len < 16 || pcm_len > (size_t)len - 16) return;
    int16_t *samples = (int16_t *)malloc(sample_count * sizeof(int16_t));
    if (!samples) return;
    const uint8_t *pcm = buf + 16;
    for (size_t i = 0; i < sample_count; i++) samples[i] = read_le16s(pcm + i * 2);
    rctl_http_push_pcm_s16le(gHttp, samples, frames, channels, sample_rate, pts_us);
    free(samples);
}

static bool read_full_fd(int fd, void *buf, size_t n) {
    uint8_t *p = (uint8_t *)buf;
    size_t off = 0;
    while (off < n) {
        ssize_t k = read(fd, p + off, n - off);
        if (k == 0) return false;
        if (k < 0) { if (errno == EINTR) continue; return false; }
        off += (size_t)k;
    }
    return true;
}

static void pump_audio_frames_fd(int fd) {
    for (;;) {
        uint8_t hdr[5];
        if (!read_full_fd(fd, hdr, sizeof(hdr))) return;
        uint8_t type = hdr[0];
        uint32_t len = ((uint32_t)hdr[1] << 24) | ((uint32_t)hdr[2] << 16) |
                       ((uint32_t)hdr[3] << 8)  |  (uint32_t)hdr[4];
        if (len > (4u << 20)) return;
        uint8_t *buf = len ? (uint8_t *)malloc(len) : NULL;
        if (len && !buf) return;
        if (len && !read_full_fd(fd, buf, len)) { free(buf); return; }
        if (type == RCTL_MSG_AUDIO) handle_audio_packet(buf, len);
        free(buf);
    }
}

static void url_decode(const char *in, char *out, size_t outsz) {
    size_t o = 0;
    for (size_t i = 0; in[i] && o + 1 < outsz; i++) {
        char c = in[i];
        if (c == '+') out[o++] = ' ';
        else if (c == '%' && in[i+1] && in[i+2]) {
            char h[3] = { in[i+1], in[i+2], 0 }; out[o++] = (char)strtol(h, NULL, 16); i += 2;
        } else out[o++] = c;
    }
    out[o] = 0;
}

static bool get_param(const char *query, const char *key, char *out, size_t outsz) {
    size_t klen = strlen(key);
    for (const char *p = query; p && *p; ) {
        if (strncmp(p, key, klen) == 0 && p[klen] == '=') {
            const char *v = p + klen + 1, *e = strchr(v, '&');
            size_t len = e ? (size_t)(e - v) : strlen(v);
            if (len >= outsz) len = outsz - 1;
            memcpy(out, v, len); out[len] = 0; return true;
        }
        p = strchr(p, '&'); if (p) p++;
    }
    return false;
}
static double get_d(const char *q, const char *k, double def) { char b[64]; return get_param(q,k,b,sizeof b) ? atof(b) : def; }
static int    get_i(const char *q, const char *k, int def)    { char b[64]; return get_param(q,k,b,sizeof b) ? atoi(b) : def; }

static double parse_json_number(const char *json, const char *key, double def) {
    if (!json || !key) return def;
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\":", key);
    char *p = strstr((char *)json, pat);
    return p ? atof(p + strlen(pat)) : def;
}

static double query_device_volume(void) {
    char *info = sb_query(RCTL_Q_AUDIOOUT, NULL, 0, 1.5);
    double v = parse_json_number(info, "volume", -1.0);
    free(info);
    return v;
}

static void set_device_volume(double v) {
    if (v < 0) v = 0; else if (v > 1) v = 1;
    int permille = (int)(v * 1000.0 + 0.5);
    ipc_key(0xF2, permille, 1);
}

static char *audio_output_status_json(void) {
    double volume = query_device_volume();
    pthread_mutex_lock(&gAudioOutputLock);
    bool enabled = gDeviceAudioEnabled;
    double saved = gSavedDeviceVolume;
    pthread_mutex_unlock(&gAudioOutputLock);
    char body[192];
    snprintf(body, sizeof(body),
             "{\"ok\":true,\"device\":%s,\"volume\":%.3f,\"saved\":%.3f}",
             enabled ? "true" : "false", volume < 0 ? 0.0 : volume, saved);
    return strdup(body);
}

static bool set_device_audio_enabled(bool enabled) {
    pthread_mutex_lock(&gAudioOutputLock);
    if (!enabled) {
        double current = query_device_volume();
        if (current > 0.02) gSavedDeviceVolume = current;
        gDeviceAudioEnabled = false;
        pthread_mutex_unlock(&gAudioOutputLock);
        set_device_volume(0.0);
        dlog("device audio muted");
        return true;
    }
    double restore = gSavedDeviceVolume;
    if (restore < 0.02) restore = 0.5;
    gDeviceAudioEnabled = true;
    pthread_mutex_unlock(&gAudioOutputLock);
    set_device_volume(restore);
    dlog("device audio restored");
    return true;
}

// US-keyboard ASCII -> HID usage (page 0x07); *shift set when the char needs Shift.
static int ascii_to_hid(unsigned char c, int *shift) {
    *shift = 0;
    if (c >= 'a' && c <= 'z') return 0x04 + (c - 'a');
    if (c >= 'A' && c <= 'Z') { *shift = 1; return 0x04 + (c - 'A'); }
    if (c >= '1' && c <= '9') return 0x1E + (c - '1');
    if (c == '0') return 0x27;
    switch (c) {
        case ' ': return 0x2C; case '\n': case '\r': return 0x28; case '\t': return 0x2B;
        case '-': return 0x2D; case '_': *shift=1; return 0x2D;
        case '=': return 0x2E; case '+': *shift=1; return 0x2E;
        case '[': return 0x2F; case '{': *shift=1; return 0x2F;
        case ']': return 0x30; case '}': *shift=1; return 0x30;
        case '\\':return 0x31; case '|': *shift=1; return 0x31;
        case ';': return 0x33; case ':': *shift=1; return 0x33;
        case '\'':return 0x34; case '"': *shift=1; return 0x34;
        case '`': return 0x35; case '~': *shift=1; return 0x35;
        case ',': return 0x36; case '<': *shift=1; return 0x36;
        case '.': return 0x37; case '>': *shift=1; return 0x37;
        case '/': return 0x38; case '?': *shift=1; return 0x38;
        case '!': *shift=1; return 0x1E; case '@': *shift=1; return 0x1F;
        case '#': *shift=1; return 0x20; case '$': *shift=1; return 0x21;
        case '%': *shift=1; return 0x22; case '^': *shift=1; return 0x23;
        case '&': *shift=1; return 0x24; case '*': *shift=1; return 0x25;
        case '(': *shift=1; return 0x26; case ')': *shift=1; return 0x27;
    }
    return 0;
}

static void schedule_tap(double x, double y, double t0) {
    AFTER(t0,        ^{ ipc_input(0, x, y); });
    AFTER(t0 + 0.05, ^{ ipc_input(2, x, y); });
}
static void schedule_swipe(double x1, double y1, double x2, double y2, double ms, double t0) {
    const int steps = 12; double dur = ms / 1000.0;
    AFTER(t0, ^{ ipc_input(0, x1, y1); });
    for (int i = 1; i < steps; i++) {
        double f = (double)i / steps, x = x1 + (x2 - x1) * f, y = y1 + (y2 - y1) * f;
        AFTER(t0 + dur * f, ^{ ipc_input(1, x, y); });
    }
    AFTER(t0 + dur, ^{ ipc_input(2, x2, y2); });
}
// Types ASCII as discrete key taps (shift held around each upper/symbol). Returns duration.
static double schedule_type(const char *text, double t0) {
    if (!text) return 0;
    double t = t0; const double dt = 0.014;
    for (size_t i = 0; text[i]; i++) {
        int shift; int u = ascii_to_hid((unsigned char)text[i], &shift);
        if (!u) continue;
        AFTER(t, ^{ if (shift) ipc_key(7, 0xE1, 1); ipc_key(7, u, 2); if (shift) ipc_key(7, 0xE1, 0); });
        t += dt;
    }
    return t - t0;
}
static void schedule_button(const char *name, double t0) {
    if (!name) return;
    int usage = !strcmp(name,"home") ? 0x40 : !strcmp(name,"lock") ? 0x30 :
                !strcmp(name,"volup") ? 0xE9 : !strcmp(name,"voldn") ? 0xEA : 0;
    if (usage) { AFTER(t0, ^{ ipc_key(12, usage, 1); }); AFTER(t0 + 0.07, ^{ ipc_key(12, usage, 0); }); }
    else if (!strcmp(name,"cc"))    AFTER(t0, ^{ ipc_key(0xF0, 1, 1); });
    else if (!strcmp(name,"shade")) AFTER(t0, ^{ ipc_key(0xF0, 2, 1); });
}

// POST /v1/script body: {"actions":[{"type":"launch","bundle":".."},{"type":"wait","ms":1500},
//   {"type":"tap","x":0.5,"y":0.9},{"type":"type","text":"hi"},{"type":"button","name":"home"}]}
static char *run_script(const char *body, int *status) {
    NSData *d = [NSData dataWithBytes:body length:strlen(body)];
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    NSArray *actions = [obj isKindOfClass:[NSDictionary class]] ? obj[@"actions"]
                     : [obj isKindOfClass:[NSArray class]] ? obj : nil;
    if (![actions isKindOfClass:[NSArray class]]) { *status = 400; return strdup("{\"error\":\"expected {actions:[...]}\"}"); }
    __block double t = 0;
    for (NSDictionary *a in actions) {
        if (![a isKindOfClass:[NSDictionary class]]) continue;
        NSString *type = a[@"type"];
        if      ([type isEqual:@"wait"])  { t += [a[@"ms"] doubleValue] / 1000.0; }
        else if ([type isEqual:@"tap"])   { schedule_tap([a[@"x"] doubleValue], [a[@"y"] doubleValue], t); t += 0.12; }
        else if ([type isEqual:@"swipe"]) { double ms = [a[@"ms"] doubleValue]; if (ms <= 0) ms = 300;
                                            schedule_swipe([a[@"x1"] doubleValue],[a[@"y1"] doubleValue],
                                                           [a[@"x2"] doubleValue],[a[@"y2"] doubleValue], ms, t); t += ms/1000.0 + 0.05; }
        else if ([type isEqual:@"type"])  { t += schedule_type([a[@"text"] UTF8String], t) + 0.05; }
        else if ([type isEqual:@"button"]){ schedule_button([a[@"name"] UTF8String], t); t += 0.2; }
        else if ([type isEqual:@"key"])   { int p = a[@"p"] ? [a[@"p"] intValue] : 7, u = [a[@"u"] intValue],
                                            dn = a[@"d"] ? [a[@"d"] intValue] : 2; AFTER(t, ^{ ipc_key(p, u, dn); }); t += 0.05; }
        else if ([type isEqual:@"launch"]){ NSString *b = a[@"bundle"];
                                            if (b) { const char *bs = strdup([b UTF8String]);
                                                     AFTER(t, ^{ send_to_sb(RCTL_MSG_LAUNCH, bs, (uint32_t)strlen(bs)); free((void*)bs); }); }
                                            t += 0.8; }
    }
    return strdup("{\"ok\":true}");
}

// List a directory as JSON {path, entries:[{name,dir,size}]}, dirs first then name.
static char *list_dir(const char *dir, int *status) {
    DIR *d = opendir(dir);
    if (!d) { *status = 404; return strdup("{\"error\":\"cannot open directory\"}"); }
    NSMutableArray *entries = [NSMutableArray array];
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        NSString *name = [NSString stringWithUTF8String:e->d_name];
        if (!name) continue;                       // skip names that aren't valid UTF-8
        char full[3072]; snprintf(full, sizeof full, "%s/%s", dir, e->d_name);
        struct stat st; BOOL isdir = NO; long long size = 0;
        if (lstat(full, &st) == 0) { isdir = S_ISDIR(st.st_mode); size = (long long)st.st_size; }
        [entries addObject:@{ @"name": name, @"dir": @(isdir), @"size": @(size) }];
    }
    closedir(d);
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL ad = [a[@"dir"] boolValue], bd = [b[@"dir"] boolValue];
        if (ad != bd) return ad ? NSOrderedAscending : NSOrderedDescending;   // directories first
        return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
    }];
    NSDictionary *obj = @{ @"path": ([NSString stringWithUTF8String:dir] ?: @""), @"entries": entries };
    NSData *jd = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    char *out = (char *)malloc(jd.length + 1); memcpy(out, jd.bytes, jd.length); out[jd.length] = 0;
    return out;
}

static char *rest_handler(void *ctx, const char *path, const char *query, const char *body,
                          int body_len, int *status, int *out_len, const char **out_ctype) {
    *status = 200;
    if (!strcmp(path, "/v1/tap")) {
        schedule_tap(get_d(query,"x",0), get_d(query,"y",0), 0);
    } else if (!strcmp(path, "/v1/swipe")) {
        schedule_swipe(get_d(query,"x1",0), get_d(query,"y1",0), get_d(query,"x2",0), get_d(query,"y2",0), get_d(query,"ms",300), 0);
    } else if (!strcmp(path, "/v1/key")) {
        ipc_key(get_i(query,"p",7), get_i(query,"u",0), get_i(query,"d",2));
    } else if (!strcmp(path, "/v1/button")) {
        char name[32]; if (!get_param(query,"name",name,sizeof name)) { *status = 400; return strdup("{\"error\":\"name required\"}"); }
        schedule_button(name, 0);
    } else if (!strcmp(path, "/v1/type")) {
        char raw[4096], text[4096];
        if (!get_param(query,"text",raw,sizeof raw)) { *status = 400; return strdup("{\"error\":\"text required\"}"); }
        url_decode(raw, text, sizeof text); schedule_type(text, 0);
    } else if (!strcmp(path, "/v1/launch")) {
        char bundle[256]; if (!get_param(query,"bundle",bundle,sizeof bundle)) { *status = 400; return strdup("{\"error\":\"bundle required\"}"); }
        send_to_sb(RCTL_MSG_LAUNCH, bundle, (uint32_t)strlen(bundle));
    } else if (!strcmp(path, "/v1/alert")) {
        char rawT[256], rawM[1024], title[256], msg[1024];
        get_param(query,"title",rawT,sizeof rawT); url_decode(rawT, title, sizeof title);
        if (!get_param(query,"message",rawM,sizeof rawM) && !title[0]) { *status = 400; return strdup("{\"error\":\"title or message required\"}"); }
        url_decode(rawM, msg, sizeof msg);
        char payload[1300]; int pn = snprintf(payload, sizeof payload, "%s\n%s", title, msg);
        send_to_sb(RCTL_MSG_ALERT, payload, (uint32_t)pn);
    } else if (!strcmp(path, "/v1/toast")) {
        char raw[1024], text[1024];
        if (!get_param(query,"text",raw,sizeof raw)) { *status = 400; return strdup("{\"error\":\"text required\"}"); }
        url_decode(raw, text, sizeof text);
        send_to_sb(RCTL_MSG_TOAST, text, (uint32_t)strlen(text));
    } else if (!strcmp(path, "/v1/respring")) {
        // Restart SpringBoard (we're root). Delay so the HTTP reply goes out first.
        AFTER(0.2, ^{ respring_device(); });
    } else if (!strcmp(path, "/v1/brightness")) {
        double v = get_d(query, "v", -1);
        if (v < 0) { *status = 400; return strdup("{\"error\":\"v (0..1) required\"}"); }
        int permille = (int)(v * 1000 + 0.5); if (permille > 1000) permille = 1000;
        ipc_key(0xF1, permille, 1);          // page 0xF1 sentinel -> SB sets UIScreen brightness
    } else if (!strcmp(path, "/v1/audio_capture")) {
        if (strstr(query, "status=1") || (!strstr(query, "on=1") && !strstr(query, "on=0"))) {
            return audio_capture_status_json();
        }
        char err[128] = {0};
        bool on = strstr(query, "on=1") != NULL;
        if (!audio_capture_set(on, err, sizeof(err))) {
            *status = 500;
            char out[192];
            snprintf(out, sizeof(out), "{\"ok\":false,\"error\":\"%s\"}", err[0] ? err : "audio capture failed");
            return strdup(out);
        }
        return audio_capture_status_json();
    } else if (!strcmp(path, "/v1/audio_output")) {
        if (strstr(query, "status=1") || (!strstr(query, "device=1") && !strstr(query, "device=0") &&
                                          !strstr(query, "mode=browser") && !strstr(query, "mode=both"))) {
            return audio_output_status_json();
        }
        bool deviceOn = strstr(query, "device=0") || strstr(query, "mode=browser") ? false : true;
        set_device_audio_enabled(deviceOn);
        return audio_output_status_json();
    } else if (!strcmp(path, "/v1/clipboard")) {
        if (body && body[0]) {            // POST body -> set the pasteboard
            send_to_sb(RCTL_MSG_SETCLIP, body, (uint32_t)strlen(body));
        } else {                          // GET -> read the pasteboard
            char *clip = sb_query(RCTL_Q_CLIPBOARD, NULL, 0, 1.5);
            NSString *s = clip ? ([NSString stringWithUTF8String:clip] ?: @"") : @"";
            free(clip);
            NSData *jd = [NSJSONSerialization dataWithJSONObject:@{@"text": s} options:0 error:nil];
            char *out = (char *)malloc(jd.length + 1); memcpy(out, jd.bytes, jd.length); out[jd.length] = 0;
            return out;
        }
    } else if (!strcmp(path, "/v1/deviceinfo")) {
        char *info = sb_query(RCTL_Q_DEVINFO, NULL, 0, 1.5);
        if (info) return info;            // SB already returns JSON
        *status = 504; return strdup("{\"error\":\"no reply from device\"}");
    } else if (!strcmp(path, "/v1/apps")) {
        char *apps = sb_query(RCTL_Q_APPLIST, NULL, 0, 3.0);   // enumeration can be slower
        if (apps) return apps;            // JSON array [{id,name}]
        *status = 504; return strdup("[]");
    } else if (!strcmp(path, "/v1/openurl")) {
        char raw[1024], url[1024];
        if (!get_param(query,"url",raw,sizeof raw)) { *status = 400; return strdup("{\"error\":\"url required\"}"); }
        url_decode(raw, url, sizeof url);
        send_to_sb(RCTL_MSG_OPENURL, url, (uint32_t)strlen(url));
    } else if (!strcmp(path, "/v1/script")) {
        return run_script(body, status);
    } else if (!strcmp(path, "/v1/ls")) {
        char raw[1024], dir[1024];
        if (!get_param(query, "path", raw, sizeof raw)) { *status = 400; return strdup("{\"error\":\"path required\"}"); }
        url_decode(raw, dir, sizeof dir);
        return list_dir(dir, status);
    } else if (!strcmp(path, "/v1/pull")) {       // download a file -> raw bytes
        char raw[1024], file[1024];
        if (!get_param(query, "path", raw, sizeof raw)) { *status = 400; return strdup("{\"error\":\"path required\"}"); }
        url_decode(raw, file, sizeof file);
        struct stat st;
        if (stat(file, &st) != 0) { *status = 404; return strdup("{\"error\":\"not found\"}"); }
        if (S_ISDIR(st.st_mode))  { *status = 400; return strdup("{\"error\":\"is a directory\"}"); }
        if (st.st_size > (64 << 20)) { *status = 400; return strdup("{\"error\":\"too large (>64MB)\"}"); }
        FILE *f = fopen(file, "rb");
        if (!f) { *status = 500; return strdup("{\"error\":\"cannot open\"}"); }
        long sz = st.st_size; char *buf = (char *)malloc(sz > 0 ? sz : 1);
        size_t rd = fread(buf, 1, sz, f); fclose(f);
        *out_len = (int)rd; *out_ctype = "application/octet-stream";
        return buf;
    } else if (!strcmp(path, "/v1/push")) {       // upload: POST body bytes -> file
        char raw[1024], file[1024];
        if (!get_param(query, "path", raw, sizeof raw)) { *status = 400; return strdup("{\"error\":\"path required\"}"); }
        url_decode(raw, file, sizeof file);
        FILE *f = fopen(file, "wb");
        if (!f) { *status = 500; return strdup("{\"error\":\"cannot write\"}"); }
        if (body_len > 0) fwrite(body, 1, body_len, f);
        fclose(f);
        char out[96]; snprintf(out, sizeof out, "{\"ok\":true,\"bytes\":%d}", body_len);
        return strdup(out);
    } else if (!strcmp(path, "/v1/rm")) {
        char raw[1024], target[1024];
        if (!get_param(query, "path", raw, sizeof raw)) { *status = 400; return strdup("{\"error\":\"path required\"}"); }
        url_decode(raw, target, sizeof target);
        struct stat st;
        int rc = (stat(target, &st) == 0 && S_ISDIR(st.st_mode)) ? rmdir(target) : unlink(target);
        if (rc != 0) { *status = 500; return strdup("{\"error\":\"delete failed\"}"); }
    } else if (!strcmp(path, "/v1/say")) {            // FX: speak text aloud
        char raw[2048], text[2048];
        if (!get_param(query, "text", raw, sizeof raw)) { *status = 400; return strdup("{\"error\":\"text required\"}"); }
        url_decode(raw, text, sizeof text);
        float pitch = (float)get_d(query, "pitch", 0), rate = (float)get_d(query, "rate", 0);
        int tl = (int)strlen(text); char *buf = (char *)malloc(9 + tl);
        buf[0] = 1; memcpy(buf + 1, &pitch, 4); memcpy(buf + 5, &rate, 4); memcpy(buf + 9, text, tl);
        send_to_sb(RCTL_MSG_FX, buf, (uint32_t)(9 + tl)); free(buf);
    } else if (!strcmp(path, "/v1/sound")) {          // FX: play a system sound id
        uint32_t id = (uint32_t)get_i(query, "id", 1007);
        uint8_t buf[5]; buf[0] = 2; memcpy(buf + 1, &id, 4);
        send_to_sb(RCTL_MSG_FX, buf, 5);
    } else if (!strcmp(path, "/v1/flash")) {          // FX: strobe the screen
        int times = get_i(query, "times", 6), r = 255, g = 0, b = 0; char col[16];
        if (get_param(query, "color", col, sizeof col)) { unsigned v = (unsigned)strtoul(col, NULL, 16); r = (v >> 16) & 255; g = (v >> 8) & 255; b = v & 255; }
        else { r = get_i(query, "r", 255); g = get_i(query, "g", 0); b = get_i(query, "b", 0); }
        uint8_t buf[5] = { 3, (uint8_t)times, (uint8_t)r, (uint8_t)g, (uint8_t)b };
        send_to_sb(RCTL_MSG_FX, buf, 5);
    } else if (!strcmp(path, "/v1/banner")) {         // FX: fullscreen text
        char raw[2048], text[2048];
        if (!get_param(query, "text", raw, sizeof raw)) { *status = 400; return strdup("{\"error\":\"text required\"}"); }
        url_decode(raw, text, sizeof text);
        float secs = (float)get_d(query, "secs", 3);
        int tl = (int)strlen(text); char *buf = (char *)malloc(5 + tl);
        buf[0] = 4; memcpy(buf + 1, &secs, 4); memcpy(buf + 5, text, tl);
        send_to_sb(RCTL_MSG_FX, buf, (uint32_t)(5 + tl)); free(buf);
    } else if (!strcmp(path, "/v1/spook")) {          // FX combo: banner + strobe + creepy voice
        char raw[2048], text[2048];
        if (get_param(query, "text", raw, sizeof raw)) url_decode(raw, text, sizeof text);
        else strncpy(text, "I SEE YOU", sizeof text);
        int tl = (int)strlen(text);
        float secs = 4.0f; char *bn = (char *)malloc(5 + tl);
        bn[0] = 4; memcpy(bn + 1, &secs, 4); memcpy(bn + 5, text, tl);
        send_to_sb(RCTL_MSG_FX, bn, (uint32_t)(5 + tl)); free(bn);
        uint8_t fl[5] = { 3, 6, 255, 0, 0 };
        send_to_sb(RCTL_MSG_FX, fl, 5);
        float pitch = 0.45f, rate = 0.38f; char *sy = (char *)malloc(9 + tl);
        sy[0] = 1; memcpy(sy + 1, &pitch, 4); memcpy(sy + 5, &rate, 4); memcpy(sy + 9, text, tl);
        send_to_sb(RCTL_MSG_FX, sy, (uint32_t)(9 + tl)); free(sy);
    } else if (!strcmp(path, "/v1/cam_upload")) {     // the in-app capturer POSTs its JPEG here
        if (body_len > 0) {
            FILE *f = fopen("/tmp/rctl_cam.jpg", "wb");
            if (f) { fwrite(body, 1, body_len, f); fclose(f); }
        }
        // -> default {"ok":true}
    } else if (!strcmp(path, "/v1/camera")) {         // snap a photo IN the frontmost app
        int pos = 1; char posp[16];                   // 1=back, 2=front
        if (get_param(query, "pos", posp, sizeof posp) && (!strcmp(posp, "front") || !strcmp(posp, "2"))) pos = 2;
        const char *out = "/tmp/rctl_cam.jpg";
        unlink(out);
        notify_post(pos == 2 ? "com.greatlove.rctl.cam.front" : "com.greatlove.rctl.cam.back");
        struct stat st; int ready = 0;                // wait for the active app to produce the JPEG
        for (int i = 0; i < 70; i++) { usleep(50000); if (stat(out, &st) == 0 && st.st_size > 0) { ready = 1; break; } }
        if (!ready) { *status = 500; return strdup("{\"error\":\"no foreground app captured (open an app, grant camera)\"}"); }
        usleep(120000);                               // let the write settle
        FILE *f = fopen(out, "rb");
        if (!f) { *status = 500; return strdup("{\"error\":\"no image file\"}"); }
        fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
        if (sz <= 0 || sz > (32 << 20)) { fclose(f); *status = 500; return strdup("{\"error\":\"bad image\"}"); }
        char *buf = (char *)malloc(sz); size_t rd = fread(buf, 1, sz, f); fclose(f);
        *out_len = (int)rd; *out_ctype = "image/jpeg";
        return buf;
    } else {
        *status = 404; return strdup("{\"error\":\"unknown action\"}");
    }
    return strdup("{\"ok\":true}");
}

// Accept the SB agent, pump its messages to the HTTP server, re-accept on drop.
static void *audio_ipc_thread(void *unused) {
    rctl_ipc_server *srv = rctl_ipc_listen(RCTL_AUDIO_IPC_SOCK_PATH);
    if (!srv) { dlog("audio ipc listen FAILED"); return NULL; }
    dlog("audio ipc listening");
    for (;;) {
        rctl_ipc *peer = rctl_ipc_accept(srv);
        if (!peer) { usleep(100000); continue; }
        dlog("audio source connected");

        uint8_t type; uint8_t *buf; uint32_t len;
        while (rctl_ipc_recv(peer, &type, &buf, &len)) {
            if (type == RCTL_MSG_AUDIO) handle_audio_packet(buf, len);
            free(buf);
        }

        dlog("audio source disconnected");
        rctl_ipc_close(peer);
    }
}

static void *audio_tcp_thread(void *unused) {
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) { dlog("audio tcp socket FAILED"); return NULL; }
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(RCTL_AUDIO_TCP_PORT);
    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        dlog("audio tcp bind FAILED");
        close(lfd);
        return NULL;
    }
    if (listen(lfd, 4) < 0) {
        dlog("audio tcp listen FAILED");
        close(lfd);
        return NULL;
    }
    dlog("audio tcp listening on 127.0.0.1:8079");
    for (;;) {
        int fd = accept(lfd, NULL, NULL);
        if (fd < 0) { usleep(100000); continue; }
        dlog("audio tcp source connected");
        pump_audio_frames_fd(fd);
        dlog("audio tcp source disconnected");
        close(fd);
    }
}

static void *ipc_thread(void *unused) {
    rctl_ipc_server *srv = rctl_ipc_listen(RCTL_IPC_SOCK_PATH);
    if (!srv) { dlog("ipc listen FAILED"); return NULL; }
    dlog("ipc listening");
    for (;;) {
        rctl_ipc *peer = rctl_ipc_accept(srv);
        if (!peer) { usleep(100000); continue; }
        dlog("SB connected");
        pthread_mutex_lock(&gSBLock); gSB = peer; pthread_mutex_unlock(&gSBLock);
        // Sync the (re)connected SB agent to the current state: if a viewer is
        // already watching (e.g. SB resprang mid-session) wake it; else stay idle.
        send_active(rctl_http_has_clients(gHttp));

        uint8_t type; uint8_t *buf; uint32_t len;
        while (rctl_ipc_recv(peer, &type, &buf, &len)) {
            if (type == RCTL_MSG_VIDEO && len >= 9) {
                rctl_http_push_au(gHttp, buf + 9, len - 9, buf[0] != 0, read_be64(buf + 1));
            } else if (type == RCTL_MSG_ORIENT && len >= 1) {
                rctl_http_set_orientation(gHttp, buf[0]);
            } else if (type == RCTL_MSG_REPLY && len >= 4) {
                uint32_t reqid = ((uint32_t)buf[0] << 24) | ((uint32_t)buf[1] << 16) | ((uint32_t)buf[2] << 8) | buf[3];
                deliver_reply(reqid, buf + 4, len - 4);
            }
            free(buf);
        }

        dlog("SB disconnected");
        pthread_mutex_lock(&gSBLock);
        if (gSB == peer) gSB = NULL;
        pthread_mutex_unlock(&gSBLock);
        rctl_ipc_close(peer);
    }
}

int main(int argc, char **argv) {
    // Safe signature validator: dlopen a dylib in THIS process (not SpringBoard).
    // If the code signature is rejected by AMFI, __TEXT stays non-executable and
    // either dlopen fails or this process crashes — never touching SpringBoard.
    if (argc >= 3 && strcmp(argv[1], "--checkload") == 0) {
        // RTLD_LAZY defers symbol binding, so a failure here isolates code-signing
        // (mapping rejection) from missing-symbol issues that only matter inside
        // SpringBoard. RTLD_NOW would also fail on our private/dlsym'd symbols.
        void *h = dlopen(argv[2], RTLD_LAZY);
        if (h) { printf("LOADOK\n"); return 0; }
        printf("LOADFAIL %s\n", dlerror() ? dlerror() : "(null)");
        return 1;
    }

    @autoreleasepool {
        dlog("rctld started");
        rctl_relay_config relayConfig = load_relay_config();
        (void)relayConfig; // Relay transport is wired in the next phase.

        // Port 8080 may briefly still be held by the old SpringBoard-hosted server
        // during an upgrade respring — retry the bind instead of dying.
        for (int i = 0; i < 30 && !gHttp; i++) {
            gHttp = rctl_http_start(8080);
            if (!gHttp) { dlog("http bind busy, retrying"); sleep(1); }
        }
        if (!gHttp) { dlog("http start FAILED"); return 1; }
        rctl_http_set_input(gHttp, on_input, NULL);
        rctl_http_set_key(gHttp, on_key, NULL);
        rctl_http_set_reconfigure(gHttp, on_reconfigure, NULL);
        gAuto = dispatch_queue_create("com.greatlove.rctl.auto", DISPATCH_QUEUE_SERIAL);
        rctl_http_set_rest(gHttp, rest_handler, NULL);
        rctl_http_set_session(gHttp, on_session, NULL);   // wake/idle SB on viewer presence
        dlog("http listening on :8080");
        audio_capture_set(false, NULL, 0);

        pthread_t t;
        pthread_create(&t, NULL, ipc_thread, NULL);
        pthread_t at;
        pthread_create(&at, NULL, audio_ipc_thread, NULL);
        pthread_t tt;
        pthread_create(&tt, NULL, audio_tcp_thread, NULL);

        dispatch_main();
    }
    return 0;
}
