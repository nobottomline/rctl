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
#import <objc/message.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <pthread.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import <time.h>
#import <dlfcn.h>
#import <spawn.h>
#import <dirent.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/socket.h>
#import <sys/wait.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <errno.h>
#import <notify.h>
#import <fcntl.h>
#import <sys/mount.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <mach/mach.h>
#import <stdlib.h>
#import <mach-o/dyld.h>
#import "net/HttpStreamServer.h"
#import "net/RelayClient.h"
#import "ipc/Ipc.h"
#import "net/WebRTCBridge.h"
#import "net/CameraIngest.h"
#import "net/MediaActivityPolicy.h"
#import "net/MediaLibrary.h"
#import "net/VirtualMicServer.h"

extern char **environ;
extern "C" int memorystatus_control(uint32_t command, pid_t pid, uint32_t flags,
                                    void *buffer, size_t buffer_size);

// Private but stable Darwin SPI used by launchd itself. iOS 14 assigns a
// third-party daemon a 6 MB fatal limit regardless of JetsamProperties in its
// plist. Command 6 sets active/inactive fatal limits for this process in MB.
// Keeping a hard ceiling protects the device while allowing WebRTC and one
// serialized ImageIO/AVFoundation preview render to coexist.
static constexpr uint32_t kMemorystatusSetJetsamTaskLimit = 6;
static constexpr uint32_t kRctldMemoryLimitMB = 128;

#define RCTL_AUDIO_PAYLOAD_DYLIB "/usr/local/lib/rctl/audio/rctlaudio.dylib"
#define RCTL_AUDIO_PAYLOAD_PLIST "/usr/local/lib/rctl/audio/rctlaudio.plist"
#define RCTL_AUDIO_ACTIVE_DYLIB "/Library/MobileSubstrate/DynamicLibraries/rctlaudio.dylib"
#define RCTL_AUDIO_ACTIVE_PLIST "/Library/MobileSubstrate/DynamicLibraries/rctlaudio.plist"
#define RCTL_AUDIO_CAPTURE_MARKER "/tmp/rctl-audio-capture"
#define RCTL_AUDIO_TONE_MARKER "/tmp/rctl-audio-tone"
#define RCTL_AUDIO_LOG "/tmp/rctl-audio.log"
static void respring_device(void) {
    pid_t pid;
    char *argv[] = { (char *)"killall", (char *)"SpringBoard", NULL };
    posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, argv, environ);
}

static void dlog(const char *msg) {
    FILE *f = fopen("/tmp/rctld.log", "a");
    if (f) { fprintf(f, "[%ld pid=%d] %s\n", (long)time(NULL), getpid(), msg); fclose(f); }
}

static void configure_memory_limit(void) {
    int result = memorystatus_control(kMemorystatusSetJetsamTaskLimit, getpid(),
                                      kRctldMemoryLimitMB, nullptr, 0);
    char message[96];
    if (result == 0) {
        snprintf(message, sizeof(message), "jetsam hard limit configured: %u MB",
                 kRctldMemoryLimitMB);
    } else {
        snprintf(message, sizeof(message), "jetsam hard limit FAILED: errno=%d", errno);
    }
    dlog(message);
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

// --- Network-driven bitrate adaptation (AIMD over /stream egress backpressure) ---
#define RCTL_BITRATE_FLOOR 600000
static pthread_mutex_t gAdaptLock = PTHREAD_MUTEX_INITIALIZER;
static int gBitrateCeiling = 20000000;   // ceiling from the last /config preset
static int gBitrateCurrent = 20000000;   // live adapted bitrate sent to SB
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

static char *delete_media_asset(const char *uuid) {
    if (!uuid) return NULL;
    return sb_query(RCTL_Q_MEDIA_DELETE, uuid, (uint32_t)strlen(uuid), 8.0);
}

static void on_input(void *ctx, int phase, int finger, double nx, double ny) {
    rctl_ipc_input m = { (int32_t)phase, (int32_t)finger, nx, ny };
    send_to_sb(RCTL_MSG_INPUT, &m, sizeof m);
}

static void on_key(void *ctx, int page, int usage, int down) {
    rctl_ipc_key m = { (int32_t)page, (int32_t)usage, (int32_t)down };
    send_to_sb(RCTL_MSG_KEY, &m, sizeof m);
}
// Adapters so the WebRTC control channel injects through the same path as /input.
static void on_webrtc_touch(int phase, int finger, double x, double y) { on_input(NULL, phase, finger, x, y); }
static void on_webrtc_key(int page, int usage, int down) { on_key(NULL, page, usage, down); }

// ---- File transfer over the WebRTC "files" DataChannel (P2P, bypasses the relay) ----
// Wire format: JSON control strings + raw binary chunks. One transfer at a time.
//   browser -> {op:get,path}          ; we reply {op:get_meta,name,size} + chunks + {op:get_eof}
//   browser -> {op:put,path,size} + chunks + {op:put_eof}  ; we reply {op:put_ok,bytes}
static FILE *gFilesUpload = NULL;
static long gFilesUploadBytes = 0;
static pthread_mutex_t gFilesLock = PTHREAD_MUTEX_INITIALIZER;
static volatile int gFilesCancel = 0;

typedef struct { char path[1024]; } files_get_arg;
static void *files_get_worker(void *a) {
    files_get_arg *arg = (files_get_arg *)a;
    struct stat st;
    if (stat(arg->path, &st) != 0 || S_ISDIR(st.st_mode)) {
        rctl_webrtc_files_send_text("{\"op\":\"err\",\"msg\":\"not found\"}"); free(arg); return NULL;
    }
    FILE *f = fopen(arg->path, "rb");
    if (!f) { rctl_webrtc_files_send_text("{\"op\":\"err\",\"msg\":\"cannot open\"}"); free(arg); return NULL; }
    const char *base = strrchr(arg->path, '/'); base = base ? base + 1 : arg->path;
    NSString *nm = [NSString stringWithUTF8String:base] ?: @"file";
    NSData *jd = [NSJSONSerialization dataWithJSONObject:@{@"op":@"get_meta", @"name":nm, @"size":@((long long)st.st_size)}
                                                 options:0 error:nil];
    char *meta = (char *)malloc(jd.length + 1); memcpy(meta, jd.bytes, jd.length); meta[jd.length] = 0;
    rctl_webrtc_files_send_text(meta); free(meta);
    const size_t CHUNK = 64 * 1024;
    uint8_t *buf = (uint8_t *)malloc(CHUNK);
    gFilesCancel = 0;
    size_t n;
    while (buf && (n = fread(buf, 1, CHUNK, f)) > 0) {
        // Backpressure: don't let the SCTP send buffer balloon in memory.
        while (rctl_webrtc_files_buffered() > (512u << 10) && !gFilesCancel) usleep(2000);
        if (gFilesCancel) break;
        rctl_webrtc_files_send_binary(buf, n);
    }
    free(buf); fclose(f);
    rctl_webrtc_files_send_text(gFilesCancel ? "{\"op\":\"get_eof\",\"cancelled\":true}" : "{\"op\":\"get_eof\"}");
    free(arg);
    return NULL;
}

static void on_files_message(const uint8_t *data, size_t len, int is_binary) {
    if (is_binary) {                       // upload chunk -> append to the open file
        pthread_mutex_lock(&gFilesLock);
        if (gFilesUpload) { fwrite(data, 1, len, gFilesUpload); gFilesUploadBytes += (long)len; }
        pthread_mutex_unlock(&gFilesLock);
        return;
    }
    NSData *nd = [NSData dataWithBytes:data length:len];
    NSDictionary *e = [NSJSONSerialization JSONObjectWithData:nd options:0 error:nil];
    if (![e isKindOfClass:[NSDictionary class]]) return;
    NSString *op = e[@"op"];
    if ([op isEqualToString:@"get"]) {
        NSString *p = e[@"path"]; if (![p isKindOfClass:[NSString class]]) return;
        files_get_arg *arg = (files_get_arg *)calloc(1, sizeof(*arg));
        if (!arg) return;
        strncpy(arg->path, p.UTF8String, sizeof(arg->path) - 1);
        pthread_t t; if (pthread_create(&t, NULL, files_get_worker, arg) == 0) pthread_detach(t); else free(arg);
    } else if ([op isEqualToString:@"put"]) {
        NSString *p = e[@"path"]; if (![p isKindOfClass:[NSString class]]) return;
        pthread_mutex_lock(&gFilesLock);
        if (gFilesUpload) fclose(gFilesUpload);
        gFilesUpload = fopen(p.UTF8String, "wb");
        gFilesUploadBytes = 0;
        int ok = gFilesUpload != NULL;
        pthread_mutex_unlock(&gFilesLock);
        if (!ok) rctl_webrtc_files_send_text("{\"op\":\"err\",\"msg\":\"cannot write\"}");
    } else if ([op isEqualToString:@"put_eof"]) {
        pthread_mutex_lock(&gFilesLock);
        long bytes = gFilesUploadBytes;
        if (gFilesUpload) { fclose(gFilesUpload); gFilesUpload = NULL; }
        pthread_mutex_unlock(&gFilesLock);
        char out[96]; snprintf(out, sizeof out, "{\"op\":\"put_ok\",\"bytes\":%ld}", bytes);
        rctl_webrtc_files_send_text(out);
    } else if ([op isEqualToString:@"cancel"]) {
        gFilesCancel = 1;
        pthread_mutex_lock(&gFilesLock);
        if (gFilesUpload) { fclose(gFilesUpload); gFilesUpload = NULL; }
        pthread_mutex_unlock(&gFilesLock);
    }
}

static void on_reconfigure(void *ctx, int fps, double scale, int bitrate) {
    rctl_ipc_config m = { (int32_t)fps, scale, (int32_t)bitrate };
    send_to_sb(RCTL_MSG_CONFIG, &m, sizeof m);
    pthread_mutex_lock(&gAdaptLock);
    gBitrateCeiling = bitrate;       // the preset is the ceiling the loop adapts under
    gBitrateCurrent = bitrate;
    pthread_mutex_unlock(&gAdaptLock);
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
static bool gStreamViewers = false;             // any /stream client
static bool gWebrtcViewers = false;             // any WebRTC video channel
static bool gCameraLive = false;                 // camera owns the hardware encoder budget
static void send_media_state(bool screen_capture, bool keep_awake) {
    uint8_t state[2] = { screen_capture ? (uint8_t)1 : (uint8_t)0,
                         keep_awake ? (uint8_t)1 : (uint8_t)0 };
    send_to_sb(RCTL_MSG_ACTIVE, state, sizeof(state));
    char message[64];
    snprintf(message, sizeof(message), "media state -> SB capture=%d awake=%d",
             screen_capture, keep_awake);
    dlog(message);
}
// Capture runs while ANY viewer watches -- /stream or WebRTC. Call on gAuto.
static void apply_active(void) {
    int gen = ++gSessionGen;
    rctl_media_activity_state state = rctl_media_activity_policy(
        gCameraLive, gStreamViewers, gWebrtcViewers);
    if (state.screen_capture || state.keep_awake)
        send_media_state(state.screen_capture, state.keep_awake);
    else AFTER(4.0, ^{
        if (gen == gSessionGen) {
            send_media_state(false, false);
            audio_capture_set(false, NULL, 0);
        }
    });
}
static void on_session(void *ctx, bool active) {
    // Debounce idle so a page refresh or brief Wi-Fi blip doesn't thrash capture.
    dispatch_async(gAuto, ^{ gStreamViewers = active; apply_active(); });
}
static void on_webrtc_keyframe_request(void) {
    // The browser asked for an intra frame (RTCP PLI). Drive the SB encoder.
    dispatch_async(gAuto, ^{ send_to_sb(RCTL_MSG_KEYFRAME, NULL, 0); });
}
static void on_webrtc_camera_keyframe_request(void) {
    notify_post("com.greatlove.rctl.cam.keyframe");
}
static void on_camera_lease_expired(void) {
    dispatch_async(gAuto, ^{
        gCameraLive = false;
        // Let the foreground app tear down AVCapture/VideoToolbox before asking
        // SpringBoard to recreate its screen encoder. Re-enabling camera during
        // the grace period cancels the resume through the state check.
        AFTER(0.75, ^{ if (!gCameraLive) apply_active(); });
    });
}
static void on_webrtc_viewers(bool any) {
    dispatch_async(gAuto, ^{
        gWebrtcViewers = any;
        apply_active();
        if (any && !gStreamViewers) {
            // The only consumer is a remote WebRTC browser (no LAN viewer). Full
            // Retina is wasted -- the viewer sees it in a small element, and every
            // extra pixel just adds encode/transmit/decode latency and keeps the
            // pipeline from holding 30fps. Encode a remote profile: half scale
            // (~834x1112) at a fixed 5 Mbps the uplink sustains. RTP fragments the
            // frames and NACK repairs loss, so this stays robust. RCTL_MSG_CONFIG
            // recreates the encoder; gate on !gStreamViewers so a LAN viewer (which
            // sends its own /config) always keeps full resolution.
            rctl_ipc_config m = { 60, 0.5, 5000000 };
            gBitrateCeiling = 5000000;
            gBitrateCurrent = 5000000;
            send_to_sb(RCTL_MSG_CONFIG, &m, sizeof m);
            send_to_sb(RCTL_MSG_KEYFRAME, NULL, 0);
        }
    });
}

static bool file_exists(const char *path) {
    return access(path, F_OK) == 0;
}

// --- /v1/diagnostics: richer device state gathered daemon-side (root) ---------
// Returns a generic {categories:[{title,fields:[{label,value}]}]} so the admin UI
// renders it without knowing the fields. Grows by adding categories below.
static NSString *diag_popen(const char *cmd) {
    FILE *p = popen(cmd, "r");
    if (!p) return nil;
    char buf[512]; NSString *out = nil;
    if (fgets(buf, sizeof buf, p))
        out = [[NSString stringWithUTF8String:buf]
                  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    pclose(p);
    return out.length ? out : nil;
}

static bool diag_port_open(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return false;
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bool ok = connect(fd, (struct sockaddr *)&a, sizeof a) == 0;
    close(fd);
    return ok;
}

static NSDictionary *diag_f(NSString *label, NSString *value) {
    return @{@"label": label, @"value": value ?: @"-"};
}

static NSString *diag_gb(double bytes) {
    return [NSString stringWithFormat:@"%.1f GB", bytes / 1e9];
}

static char *rctl_diagnostics_json(void) {
    NSMutableArray *cats = [NSMutableArray array];

    {   // Jailbreak / system
        NSMutableArray *f = [NSMutableArray array];
        [f addObject:diag_f(@"Type", file_exists("/var/jb") ? @"rootless" : @"rootful")];
        NSString *mgr = file_exists("/Applications/Sileo.app") ? @"Sileo"
                      : file_exists("/Applications/Zebra.app") ? @"Zebra"
                      : file_exists("/Applications/Cydia.app") ? @"Cydia" : nil;
        if (mgr) [f addObject:diag_f(@"Manager", mgr)];
        NSString *inj = file_exists("/usr/lib/libhooker.dylib") ? @"libhooker"
                      : (file_exists("/usr/lib/libellekit.dylib") || file_exists("/var/jb/usr/lib/libellekit.dylib")) ? @"ElleKit"
                      : file_exists("/usr/lib/libsubstitute.dylib") ? @"Substitute"
                      : file_exists("/Library/MobileSubstrate/MobileSubstrate.dylib") ? @"Substrate" : nil;
        if (inj) [f addObject:diag_f(@"Injection", inj)];
        NSString *pk = diag_popen("dpkg-query -f '.\n' -W 2>/dev/null | wc -l | tr -d ' '");
        if (pk) [f addObject:diag_f(@"Packages", pk)];
        NSString *tw = diag_popen("ls -1 /Library/MobileSubstrate/DynamicLibraries/ 2>/dev/null | grep -c '[.]dylib$' | tr -d ' '");
        if (tw) [f addObject:diag_f(@"Tweaks", tw)];
        [f addObject:diag_f(@"SSH", diag_port_open(22) ? @"running" : @"off")];
        [cats addObject:@{@"title": @"Jailbreak", @"fields": f}];
    }

    {   // Performance
        NSMutableArray *f = [NSMutableArray array];
        double la[3];
        if (getloadavg(la, 3) == 3)
            [f addObject:diag_f(@"Load avg", [NSString stringWithFormat:@"%.2f · %.2f · %.2f", la[0], la[1], la[2]])];
        unsigned long long total = [NSProcessInfo processInfo].physicalMemory;
        vm_size_t page = 0; host_page_size(mach_host_self(), &page);
        vm_statistics64_data_t vm; mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT;
        if (page && host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &cnt) == KERN_SUCCESS) {
            double freeb = (double)(vm.free_count + vm.inactive_count) * page;
            double used = (double)total - freeb; if (used < 0) used = 0;
            [f addObject:diag_f(@"Memory", [NSString stringWithFormat:@"%@ used of %@", diag_gb(used), diag_gb((double)total)])];
            [f addObject:diag_f(@"Wired", diag_gb((double)vm.wire_count * page))];
            [f addObject:diag_f(@"Compressed", diag_gb((double)vm.compressor_page_count * page))];
        }
        NSString *top = diag_popen("ps -A -o comm -r 2>/dev/null | sed -n '2p'");
        if (top) [f addObject:diag_f(@"Top process", top.lastPathComponent)];
        [cats addObject:@{@"title": @"Performance", @"fields": f}];
    }

    {   // Storage
        NSMutableArray *f = [NSMutableArray array];
        struct statfs st;
        if (statfs("/var", &st) == 0) {
            double tot = (double)st.f_blocks * st.f_bsize, fr = (double)st.f_bavail * st.f_bsize;
            [f addObject:diag_f(@"Data", [NSString stringWithFormat:@"%@ free of %@", diag_gb(fr), diag_gb(tot)])];
        }
        if (statfs("/", &st) == 0)
            [f addObject:diag_f(@"System volume", diag_gb((double)st.f_blocks * st.f_bsize))];
        if (f.count) [cats addObject:@{@"title": @"Storage", @"fields": f}];
    }

    {   // Network (up, non-loopback IPv4 interface addresses)
        NSMutableArray *f = [NSMutableArray array];
        struct ifaddrs *ifa = NULL;
        if (getifaddrs(&ifa) == 0) {
            for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
                if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
                if (!(p->ifa_flags & IFF_UP) || (p->ifa_flags & IFF_LOOPBACK)) continue;
                char ip[INET_ADDRSTRLEN];
                inet_ntop(AF_INET, &((struct sockaddr_in *)p->ifa_addr)->sin_addr, ip, sizeof ip);
                [f addObject:diag_f([NSString stringWithUTF8String:p->ifa_name], [NSString stringWithUTF8String:ip])];
            }
            freeifaddrs(ifa);
        }
        if (f.count) [cats addObject:@{@"title": @"Network", @"fields": f}];
    }

    NSData *jd = [NSJSONSerialization dataWithJSONObject:@{@"categories": cats} options:0 error:nil];
    if (!jd) return strdup("{\"categories\":[]}");
    char *out = (char *)malloc(jd.length + 1);
    memcpy(out, jd.bytes, jd.length); out[jd.length] = 0;
    return out;
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
        send_media_state(false, true);
        usleep(350000);
    }
    return resume;
}

static void resume_video_after_media_restart(bool resume) {
    if (!resume) return;
    usleep(800000);
    rctl_http_signal_reset(gHttp);
    dispatch_async(gAuto, ^{ apply_active(); });
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
                         file_exists(RCTL_AUDIO_CAPTURE_MARKER) || file_exists(RCTL_AUDIO_TONE_MARKER);
        unlink(RCTL_AUDIO_ACTIVE_DYLIB);
        unlink(RCTL_AUDIO_ACTIVE_PLIST);
        unlink(RCTL_AUDIO_CAPTURE_MARKER);
        unlink(RCTL_AUDIO_TONE_MARKER);
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
    rctl_webrtc_push_audio(samples, frames, channels, sample_rate, pts_us);
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

static AudioUnit g_micUnit = NULL;
static bool g_micCapturing = false;
static bool g_micListenWant = false;   // browser is listening to the mic
static bool g_micRecordWant = false;   // a recording is armed
static ExtAudioFileRef g_recFile = NULL;
static bool g_recording = false;
static uint64_t g_recFrames = 0;       // mono frames @ 48k written so far
static pthread_mutex_t g_recLock = PTHREAD_MUTEX_INITIALIZER;
#define RCTL_MIC_REC_PATH "/var/mobile/rctl/mic-recording.m4a"
static bool rctl_mic_capture_start(void);
static void rctl_mic_capture_stop(void);
static void rctl_mic_refresh(void);
static bool rctl_mic_record_start(void);
static void rctl_mic_record_stop(void);

// ---- System Inspector --------------------------------------------------------
// All read-only. JSON is built via NSJSONSerialization (handles escaping) and
// returned as a malloc'd C string, matching list_dir()'s contract.

// Installed packages, parsed straight from dpkg's status DB (no shelling out).
static char *rctl_packages_json(void) {
    NSString *raw = nil;
    for (NSString *p in @[ @"/var/lib/dpkg/status", @"/var/jb/var/lib/dpkg/status" ]) {
        raw = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (!raw) raw = [NSString stringWithContentsOfFile:p encoding:NSISOLatin1StringEncoding error:nil];
        if (raw) break;
    }
    NSMutableArray *pkgs = [NSMutableArray array];
    if (raw) {
        for (NSString *stanza in [raw componentsSeparatedByString:@"\n\n"]) {
            if (stanza.length == 0) continue;
            NSString *pkg = nil, *ver = nil, *name = nil, *section = nil, *desc = nil, *author = nil, *st = nil;
            NSString *home = nil, *depiction = nil, *icon = nil, *role = @"";
            long size = 0;
            for (NSString *line in [stanza componentsSeparatedByString:@"\n"]) {
                if ([line hasPrefix:@" "]) continue;            // long-description continuation
                NSRange c = [line rangeOfString:@": "];
                if (c.location == NSNotFound) continue;
                NSString *k = [line substringToIndex:c.location];
                NSString *v = [line substringFromIndex:c.location + 2];
                if ([k isEqualToString:@"Package"]) pkg = v;
                else if ([k isEqualToString:@"Version"]) ver = v;
                else if ([k isEqualToString:@"Name"]) name = v;             // Cydia display name
                else if ([k isEqualToString:@"Section"]) section = v;
                else if ([k isEqualToString:@"Author"]) author = v;
                else if ([k isEqualToString:@"Installed-Size"]) size = [v integerValue]; // KB
                else if ([k isEqualToString:@"Status"]) st = v;
                else if ([k isEqualToString:@"Description"]) desc = v;
                else if ([k isEqualToString:@"Homepage"]) home = v;
                else if ([k isEqualToString:@"Depiction"]) depiction = v;
                else if ([k isEqualToString:@"Icon"]) icon = v;
                else if ([k isEqualToString:@"Tag"]) {          // role::user/hacker/developer/cydia -> User/Expert filter
                    NSRange rr = [v rangeOfString:@"role::"];
                    if (rr.location != NSNotFound) {
                        NSString *rest = [v substringFromIndex:rr.location + 6];
                        NSRange e = [rest rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@", \t"]];
                        role = (e.location == NSNotFound) ? rest : [rest substringToIndex:e.location];
                    }
                }
            }
            if (!pkg) continue;
            if (st && [st rangeOfString:@"installed"].location == NSNotFound) continue; // not actually installed
            long installed = 0;                                 // install time = mtime of the dpkg file list
            for (NSString *info in @[ @"/var/lib/dpkg/info", @"/var/jb/var/lib/dpkg/info" ]) {
                struct stat lst;
                NSString *lp = [NSString stringWithFormat:@"%@/%@.list", info, pkg];
                if (stat(lp.fileSystemRepresentation, &lst) == 0) { installed = (long)lst.st_mtime; break; }
            }
            [pkgs addObject:@{
                @"id": pkg,
                @"name": (name.length ? name : pkg),
                @"version": (ver ?: @""),
                @"section": (section ?: @""),
                @"author": (author ?: @""),
                @"desc": (desc ?: @""),
                @"size": @((long long)size * 1024),
                @"role": role,
                @"home": (home ?: @""),
                @"depiction": (depiction ?: @""),
                @"icon": (icon ?: @""),
                @"installed": @(installed),
            }];
        }
    }
    [pkgs sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
    }];
    NSData *jd = [NSJSONSerialization dataWithJSONObject:@{ @"count": @(pkgs.count), @"packages": pkgs } options:0 error:nil];
    if (!jd) return strdup("{\"count\":0,\"packages\":[]}");
    char *out = (char *)malloc(jd.length + 1); memcpy(out, jd.bytes, jd.length); out[jd.length] = 0;
    return out;
}

// MobileSubstrate tweaks: each .dylib with its filter (which bundles/executables
// it injects into), read from the companion .plist.
static char *rctl_tweaks_json(void) {
    NSMutableArray *tweaks = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *dirs = @[ @"/Library/MobileSubstrate/DynamicLibraries", @"/usr/lib/TweakInject",
                       @"/var/jb/Library/MobileSubstrate/DynamicLibraries", @"/var/jb/usr/lib/TweakInject" ];
    for (NSString *dir in dirs) {
        for (NSString *f in ([fm contentsOfDirectoryAtPath:dir error:nil] ?: @[])) {
            BOOL disabled = [f hasSuffix:@".plist.disabled"];   // toggled off by us
            if (!disabled && ![[f pathExtension] isEqualToString:@"plist"]) continue;
            NSString *base = disabled ? [f substringToIndex:f.length - @".plist.disabled".length]
                                      : [f stringByDeletingPathExtension];
            NSString *plistPath = [dir stringByAppendingPathComponent:f];
            NSString *dylibPath = [dir stringByAppendingPathComponent:[base stringByAppendingString:(disabled ? @".dylib.disabled" : @".dylib")]];
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            NSArray *bundles = @[], *execs = @[];
            if ([plist isKindOfClass:[NSDictionary class]]) {
                NSDictionary *filter = plist[@"Filter"];
                if ([filter isKindOfClass:[NSDictionary class]]) {
                    if ([filter[@"Bundles"] isKindOfClass:[NSArray class]]) bundles = filter[@"Bundles"];
                    if ([filter[@"Executables"] isKindOfClass:[NSArray class]]) execs = filter[@"Executables"];
                }
            }
            struct stat stt; long size = (stat(dylibPath.fileSystemRepresentation, &stt) == 0) ? (long)stt.st_size : 0;
            [tweaks addObject:@{
                @"name": base,
                @"path": dylibPath,
                @"bundles": bundles,
                @"executables": execs,
                @"size": @(size),
                @"enabled": @(!disabled),
                @"present": @([fm fileExistsAtPath:dylibPath]),
            }];
        }
    }
    [tweaks sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
    }];
    NSData *jd = [NSJSONSerialization dataWithJSONObject:@{ @"count": @(tweaks.count), @"tweaks": tweaks } options:0 error:nil];
    if (!jd) return strdup("{\"count\":0,\"tweaks\":[]}");
    char *out = (char *)malloc(jd.length + 1); memcpy(out, jd.bytes, jd.length); out[jd.length] = 0;
    return out;
}

// Dynamic libraries currently mapped into this process (rctld). Anything not an OS
// image (outside /System and /usr/lib) is flagged so injected/3rd-party code shows.
static char *rctl_dylibs_json(void) {
    NSMutableArray *libs = [NSMutableArray array];
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        NSString *path = [NSString stringWithUTF8String:nm];
        if (!path) continue;
        BOOL injected = !([path hasPrefix:@"/System/"] || [path hasPrefix:@"/usr/lib/"]);
        struct stat stt; long size = (stat(nm, &stt) == 0) ? (long)stt.st_size : 0;
        [libs addObject:@{
            @"name": [path lastPathComponent],
            @"path": path,
            @"size": @(size),
            @"injected": @(injected),
        }];
    }
    [libs sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
    }];
    NSData *jd = [NSJSONSerialization dataWithJSONObject:@{ @"count": @(libs.count), @"process": @"rctld", @"dylibs": libs } options:0 error:nil];
    if (!jd) return strdup("{\"count\":0,\"dylibs\":[]}");
    char *out = (char *)malloc(jd.length + 1); memcpy(out, jd.bytes, jd.length); out[jd.length] = 0;
    return out;
}

// dpkg package ids are a tight charset; reject anything else so it can never reach
// a shell as an argument.
static bool rctl_safe_id(const char *s) {
    if (!s || !*s) return false;
    for (const char *p = s; *p; p++) {
        char c = *p;
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              c == '.' || c == '+' || c == '-' || c == '_')) return false;
    }
    return true;
}

// Enable/disable a tweak by renaming its .dylib + .plist to/from a .disabled
// suffix (Substrate only loads *.dylib, so this cleanly stops injection without
// the "no plist -> loads globally" footgun). Takes effect on the next respring.
// Returns NULL for a path outside a tweak dir so the caller can 400.
static char *rctl_tweak_toggle(const char *cpath, int on) {
    NSString *path = [NSString stringWithUTF8String:cpath] ?: @"";
    if (!([path containsString:@"/DynamicLibraries/"] || [path containsString:@"/TweakInject/"])) return NULL;
    if (!([path hasSuffix:@".dylib"] || [path hasSuffix:@".dylib.disabled"])) return NULL;
    NSString *dy = [path hasSuffix:@".disabled"] ? [path substringToIndex:path.length - @".disabled".length] : path;
    NSString *dyD = [dy stringByAppendingString:@".disabled"];
    NSString *pl = [[dy substringToIndex:dy.length - @".dylib".length] stringByAppendingString:@".plist"];
    NSString *plD = [pl stringByAppendingString:@".disabled"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (on) {
        if ([fm fileExistsAtPath:dyD]) [fm moveItemAtPath:dyD toPath:dy error:nil];
        if ([fm fileExistsAtPath:plD]) [fm moveItemAtPath:plD toPath:pl error:nil];
    } else {
        if ([fm fileExistsAtPath:dy]) [fm moveItemAtPath:dy toPath:dyD error:nil];
        if ([fm fileExistsAtPath:pl]) [fm moveItemAtPath:pl toPath:plD error:nil];
    }
    NSData *jd = [NSJSONSerialization dataWithJSONObject:@{ @"ok": @YES, @"enabled": @(on != 0) } options:0 error:nil];
    char *r = (char *)malloc(jd.length + 1); memcpy(r, jd.bytes, jd.length); r[jd.length] = 0;
    return r;
}

// Which installed package owns a file (dpkg's .list DB). Used to turn "remove this
// tweak" into "uninstall its package". Strips a .disabled suffix first.
static char *rctl_owner_json(const char *cpath) {
    NSString *target = [NSString stringWithUTF8String:cpath] ?: @"";
    if ([target hasSuffix:@".disabled"]) target = [target substringToIndex:target.length - @".disabled".length];
    NSString *found = @"";
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *info in @[ @"/var/lib/dpkg/info", @"/var/jb/var/lib/dpkg/info" ]) {
        for (NSString *f in ([fm contentsOfDirectoryAtPath:info error:nil] ?: @[])) {
            if (![f hasSuffix:@".list"]) continue;
            NSString *content = [NSString stringWithContentsOfFile:[info stringByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:nil];
            if (!content) continue;
            if ([[content componentsSeparatedByString:@"\n"] containsObject:target]) { found = [f stringByDeletingPathExtension]; break; }
        }
        if (found.length) break;
    }
    NSData *jd = [NSJSONSerialization dataWithJSONObject:@{ @"package": found } options:0 error:nil];
    char *r = (char *)malloc(jd.length + 1); memcpy(r, jd.bytes, jd.length); r[jd.length] = 0;
    return r;
}

// The files a package installed (dpkg .list).
static char *rctl_pkg_files_json(const char *id) {
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *info in @[ @"/var/lib/dpkg/info", @"/var/jb/var/lib/dpkg/info" ]) {
        NSString *lp = [NSString stringWithFormat:@"%@/%s.list", info, id];
        NSString *content = [NSString stringWithContentsOfFile:lp encoding:NSUTF8StringEncoding error:nil];
        if (!content) continue;
        for (NSString *line in [content componentsSeparatedByString:@"\n"]) if (line.length) [files addObject:line];
        break;
    }
    NSData *jd = [NSJSONSerialization dataWithJSONObject:@{ @"count": @(files.count), @"files": files } options:0 error:nil];
    char *r = (char *)malloc(jd.length + 1); memcpy(r, jd.bytes, jd.length); r[jd.length] = 0;
    return r;
}

// Uninstall a package via dpkg -r (id is pre-validated by rctl_safe_id). Captures
// dpkg's output + exit status for the UI; a respring usually follows.
static char *rctl_pkg_remove(const char *id) {
    char cmd[320];
    snprintf(cmd, sizeof cmd, "dpkg -r %s 2>&1", id);
    FILE *p = popen(cmd, "r");
    if (!p) return strdup("{\"ok\":false,\"output\":\"could not run dpkg\"}");
    NSMutableData *buf = [NSMutableData data];
    char chunk[1024]; size_t n;
    while ((n = fread(chunk, 1, sizeof chunk, p)) > 0) [buf appendBytes:chunk length:n];
    int rc = pclose(p);
    NSString *outs = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding] ?: @"";
    NSData *jd = [NSJSONSerialization dataWithJSONObject:@{ @"ok": @(rc == 0), @"output": outs } options:0 error:nil];
    char *r = (char *)malloc(jd.length + 1); memcpy(r, jd.bytes, jd.length); r[jd.length] = 0;
    return r;
}

static char *rctl_pkg_meta_json(const char *cid) {
    NSString *pkgid = [NSString stringWithUTF8String:cid] ?: @"";
    NSData *needHead = [[NSString stringWithFormat:@"Package: %@\n", pkgid] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *needMid  = [[NSString stringWithFormat:@"\nPackage: %@\n", pkgid] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *blank = [@"\n\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL done = NO;
    for (NSString *dir in @[ @"/var/lib/apt/lists", @"/var/jb/var/lib/apt/lists" ]) {
        if (done) break;
        for (NSString *f in ([fm contentsOfDirectoryAtPath:dir error:nil] ?: @[])) {
            if (done) break;
            if (![f hasSuffix:@"Packages"]) continue;
            @autoreleasepool {
                NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:f] options:NSDataReadingMappedIfSafe error:nil];
                NSUInteger start = NSNotFound;
                if (data.length >= needHead.length && memcmp(data.bytes, needHead.bytes, needHead.length) == 0) {
                    start = 0;                                  // first stanza in the file
                } else if (data.length) {
                    NSRange mr = [data rangeOfData:needMid options:0 range:NSMakeRange(0, data.length)];
                    if (mr.location != NSNotFound) start = mr.location + 1;   // past the leading '\n'
                }
                if (start != NSNotFound) {
                    NSRange er = [data rangeOfData:blank options:0 range:NSMakeRange(start, data.length - start)];
                    NSUInteger stop = (er.location == NSNotFound) ? data.length : er.location;
                    NSData *slice = [data subdataWithRange:NSMakeRange(start, stop - start)];
                    NSString *stanza = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
                    for (NSString *line in [(stanza ?: @"") componentsSeparatedByString:@"\n"]) {
                        if ([line hasPrefix:@" "]) continue;
                        NSRange c = [line rangeOfString:@": "];
                        if (c.location == NSNotFound) continue;
                        NSString *k = [line substringToIndex:c.location];
                        const char *vc = [[line substringFromIndex:c.location + 2] UTF8String];
                        NSString *v = vc ? [NSString stringWithUTF8String:vc] : @"";
                        if ([k isEqualToString:@"Depiction"]) meta[@"depiction"] = v;
                        else if ([k isEqualToString:@"Icon"]) { if (!meta[@"icon"]) meta[@"icon"] = v; }
                        else if ([k isEqualToString:@"Homepage"]) { if (!meta[@"home"]) meta[@"home"] = v; }
                        else if ([k isEqualToString:@"Description"]) { if (!meta[@"desc"]) meta[@"desc"] = v; }
                        else if ([k isEqualToString:@"Author"]) { if (!meta[@"author"]) meta[@"author"] = v; }
                        else if ([k isEqualToString:@"Maintainer"]) { if (!meta[@"maintainer"]) meta[@"maintainer"] = v; }
                        else if ([k isEqualToString:@"Section"]) { if (!meta[@"section"]) meta[@"section"] = v; }
                        else if ([k isEqualToString:@"Version"]) { if (!meta[@"version"]) meta[@"version"] = v; }
                    }
                    if (meta[@"depiction"]) done = YES;        // richest record found; stop
                }
            }
        }
    }
    NSData *jd = [NSJSONSerialization dataWithJSONObject:meta options:0 error:nil];
    if (!jd) return strdup("{}");
    char *out = (char *)malloc(jd.length + 1); memcpy(out, jd.bytes, jd.length); out[jd.length] = 0;
    return out;
}

static char *rest_handler(void *ctx, const char *method, const char *content_type,
                          const char *path, const char *query, const char *body,
                          int body_len, int *status, int *out_len, const char **out_ctype) {
    *status = 200;
    if ((!strcmp(path, "/v1/media_delete_token") || !strcmp(path, "/v1/media_delete")) &&
        (strcmp(method, "POST") || strcmp(content_type, "application/json"))) {
        *status = 403;
        return strdup("{\"error\":\"post_application_json_required\"}");
    }
    char *media = rctl_media_handle(path, query, body, body_len, status, out_len, out_ctype);
    if (media) return media;
    if (!strcmp(path, "/v1/talk_route")) {
        char mode[16] = {0};
        if (get_param(query, "mode", mode, sizeof(mode))) {
            if (!strcmp(mode, "speaker")) rctl_vmic_set_route(RCTL_TALK_SPEAKER);
            else if (!strcmp(mode, "mic")) rctl_vmic_set_route(RCTL_TALK_VIRTUAL_MIC);
            else if (!strcmp(mode, "both")) rctl_vmic_set_route(RCTL_TALK_BOTH);
            else { *status = 400; return strdup("{\"error\":\"mode must be speaker, mic, or both\"}"); }
        }
        const char *current = rctl_vmic_route() == RCTL_TALK_VIRTUAL_MIC ? "mic" :
                              rctl_vmic_route() == RCTL_TALK_BOTH ? "both" : "speaker";
        char response[192];
        snprintf(response, sizeof(response),
                 "{\"ok\":true,\"mode\":\"%s\",\"clients\":%zu,\"frames_pushed\":%llu,\"frames_broadcast\":%llu}",
                 current, rctl_vmic_client_count(),
                 (unsigned long long)rctl_vmic_frames_pushed(),
                 (unsigned long long)rctl_vmic_frames_broadcast());
        return strdup(response);
    } else if (!strcmp(path, "/v1/tap")) {
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
    } else if (!strcmp(path, "/v1/diagnostics")) {
        char *d = rctl_diagnostics_json();
        if (d) return d;
        *status = 500; return strdup("{\"error\":\"diagnostics failed\"}");
    } else if (!strcmp(path, "/v1/packages")) {       // installed dpkg packages
        char *p = rctl_packages_json();
        if (p) return p;
        *status = 500; return strdup("{\"error\":\"packages failed\"}");
    } else if (!strcmp(path, "/v1/tweaks")) {         // MobileSubstrate tweaks + filters
        char *t = rctl_tweaks_json();
        if (t) return t;
        *status = 500; return strdup("{\"error\":\"tweaks failed\"}");
    } else if (!strcmp(path, "/v1/dylibs")) {         // dylibs loaded in rctld
        char *dl = rctl_dylibs_json();
        if (dl) return dl;
        *status = 500; return strdup("{\"error\":\"dylibs failed\"}");
    } else if (!strcmp(path, "/v1/tweak_toggle")) {   // enable/disable a tweak (rename +/- .disabled)
        char raw[1024], pth[1024]; int on = get_i(query, "on", 0);
        if (!get_param(query, "path", raw, sizeof raw)) { *status = 400; return strdup("{\"error\":\"path required\"}"); }
        url_decode(raw, pth, sizeof pth);
        char *r = rctl_tweak_toggle(pth, on);
        if (r) return r;
        *status = 400; return strdup("{\"error\":\"not a tweak path\"}");
    } else if (!strcmp(path, "/v1/owner")) {          // which package owns a file
        char raw[1024], pth[1024];
        if (!get_param(query, "path", raw, sizeof raw)) { *status = 400; return strdup("{\"error\":\"path required\"}"); }
        url_decode(raw, pth, sizeof pth);
        return rctl_owner_json(pth);
    } else if (!strcmp(path, "/v1/pkg_files")) {      // files a package installed
        char id[256];
        if (!get_param(query, "id", id, sizeof id) || !rctl_safe_id(id)) { *status = 400; return strdup("{\"error\":\"bad id\"}"); }
        return rctl_pkg_files_json(id);
    } else if (!strcmp(path, "/v1/pkg_remove")) {     // dpkg -r <id>
        char id[256];
        if (!get_param(query, "id", id, sizeof id) || !rctl_safe_id(id)) { *status = 400; return strdup("{\"error\":\"bad id\"}"); }
        return rctl_pkg_remove(id);
    } else if (!strcmp(path, "/v1/pkg_meta")) {       // rich repo metadata (depiction/icon) from apt lists
        char id[256];
        if (!get_param(query, "id", id, sizeof id) || !rctl_safe_id(id)) { *status = 400; return strdup("{\"error\":\"bad id\"}"); }
        return rctl_pkg_meta_json(id);
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
    } else if (!strcmp(path, "/v1/cam_live")) {
        char onp[8];
        if (!get_param(query, "on", onp, sizeof(onp)))
            return rctl_camera_status_json();
        bool on = onp[0] == '1';
        char posp[16];
        int position = get_param(query, "pos", posp, sizeof(posp)) &&
                       (!strcmp(posp, "front") || !strcmp(posp, "2")) ? 2 : 1;
        int fps = get_i(query, "fps", 10);
        int bitrate = get_i(query, "bitrate", 1500000);
        dispatch_sync(gAuto, ^{
            if (on) {
                gCameraLive = true;
                apply_active();
                rctl_camera_set_enabled(true, position, fps, bitrate);
            } else {
                rctl_camera_set_enabled(false, position, fps, bitrate);
                gCameraLive = false;
                AFTER(0.75, ^{ if (!gCameraLive) apply_active(); });
            }
        });
        return rctl_camera_status_json();
    } else if (!strcmp(path, "/v1/cam_status")) {
        if (strstr(query, "lease=1")) rctl_camera_renew_lease();
        return rctl_camera_status_json();
    } else if (!strcmp(path, "/v1/cam_record")) {
        char value[8];
        if (get_param(query, "discard", value, sizeof(value)) && value[0] == '1') {
            rctl_camera_record_discard();
        } else if (get_param(query, "on", value, sizeof(value))) {
            if (value[0] == '1' && !rctl_camera_record_start()) {
                *status = 409;
                return strdup("{\"error\":\"start live camera before recording\"}");
            }
            if (value[0] != '1') rctl_camera_record_stop();
        }
        return rctl_camera_status_json();
    } else if (!strcmp(path, "/v1/cam_agent_state")) {
        return rctl_camera_agent_state_json();
    } else if (!strcmp(path, "/v1/cam_upload")) {     // the in-app capturer POSTs its JPEG here
        if (body_len > 0) {
            FILE *f = fopen("/tmp/rctl_cam.jpg", "wb");
            if (f) { fwrite(body, 1, body_len, f); fclose(f); }
        }
        // -> default {"ok":true}
    } else if (!strcmp(path, "/v1/mic_capture")) {    // listen to the iPad mic ANYTIME (daemon-side RemoteIO capture)
        char onp[8]; int on = 0;
        if (get_param(query, "on", onp, sizeof onp) && onp[0] == '1') on = 1;
        g_micListenWant = on;
        rctl_mic_refresh();
        if (on && !g_micCapturing) { *status = 500; return strdup("{\"error\":\"mic capture failed (see /tmp/rctld.log)\"}"); }
        // -> default {"ok":true}
    } else if (!strcmp(path, "/v1/mic_record")) {     // record the iPad mic to a file; download later via the files channel
        char onp[8], dp[8];
        if (get_param(query, "discard", dp, sizeof dp) && dp[0] == '1') {
            rctl_mic_record_stop();
            g_micRecordWant = false;
            unlink(RCTL_MIC_REC_PATH);
            rctl_mic_refresh();
            // -> default {"ok":true}
        } else if (get_param(query, "on", onp, sizeof onp)) {
            if (onp[0] == '1') {
                g_micRecordWant = true;
                rctl_mic_refresh();
                if (!rctl_mic_record_start()) { g_micRecordWant = false; rctl_mic_refresh(); *status = 500; return strdup("{\"error\":\"record start failed\"}"); }
            } else {
                rctl_mic_record_stop();
                g_micRecordWant = false;
                rctl_mic_refresh();
            }
            // -> default {"ok":true}
        } else {
            pthread_mutex_lock(&g_recLock);
            bool rec = g_recording; long fr = (long)g_recFrames;
            pthread_mutex_unlock(&g_recLock);
            struct stat stt; long bytes = (stat(RCTL_MIC_REC_PATH, &stt) == 0) ? (long)stt.st_size : 0;
            char *j = (char *)malloc(208);
            snprintf(j, 208, "{\"recording\":%s,\"seconds\":%d,\"bytes\":%ld,\"path\":\"%s\"}",
                     rec ? "true" : "false", (int)(fr / 48000), bytes, RCTL_MIC_REC_PATH);
            return j;
        }
    } else if (!strcmp(path, "/v1/camera")) {         // snap a photo IN the frontmost app
        if (rctl_camera_is_enabled()) {
            *status = 409;
            return strdup("{\"error\":\"stop live camera before taking a still\"}");
        }
        int pos = 1; char posp[16];                   // 1=back, 2=front
        if (get_param(query, "pos", posp, sizeof posp) && (!strcmp(posp, "front") || !strcmp(posp, "2"))) pos = 2;
        const char *out = "/tmp/rctl_cam.jpg";
        unlink(out);
        // A snap spins up the foreground app's camera (AVFoundation + mediaserverd) --
        // the same service the screen H.264 encoder uses. Running both at once starves
        // the encoder and spikes CPU/memory, which on this device cascades into a frozen
        // stream + a dropped relay link. So pause the screen capture/encode for the snap,
        // then resume (a fresh session emits a keyframe, so the viewer recovers fast).
        send_media_state(false, true);
        usleep(200000);                               // let the encoder + capture surface tear down
        notify_post(pos == 2 ? "com.greatlove.rctl.cam.front" : "com.greatlove.rctl.cam.back");
        struct stat st; int ready = 0;                // wait for the active app to produce the JPEG
        for (int i = 0; i < 70; i++) { usleep(50000); if (stat(out, &st) == 0 && st.st_size > 0) { ready = 1; break; } }
        dispatch_async(gAuto, ^{ apply_active(); });  // restore the actual viewer state
        if (!ready) { *status = 500; return strdup("{\"error\":\"no foreground app captured (open an app, grant camera)\"}"); }
        usleep(120000);                               // let the write settle before it's read
        char ndp[8];
        if (get_param(query, "nodata", ndp, sizeof ndp) && ndp[0] == '1') {
            // Relay path: a multi-MB body tears down the device's relay WebSocket, so
            // return only a small "ready" status; the browser pulls the JPEG over the
            // P2P files DataChannel instead.
            return strdup("{\"ready\":true,\"path\":\"/tmp/rctl_cam.jpg\"}");
        }
        // Local/direct path (no relay WS in the way): return the JPEG inline.
        FILE *f = fopen(out, "rb");
        if (!f) { *status = 500; return strdup("{\"error\":\"no image file\"}"); }
        fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
        if (sz <= 0 || sz > (32 << 20)) { fclose(f); *status = 500; return strdup("{\"error\":\"bad image\"}"); }
        char *buf = (char *)malloc(sz); size_t rd = fread(buf, 1, sz, f); fclose(f);
        *out_len = (int)rd; *out_ctype = "image/jpeg";
        return buf;
    } else if (!strcmp(path, "/v1/screenshot")) {   // full-res lossless PNG (no stream downscale/H.264)
        const char *shot = "/tmp/rctl-shot.png";
        unlink(shot);
        char *st = sb_query(RCTL_Q_SCREENSHOT, NULL, 0, 5.0);   // SB renders+encodes, then replies
        int ok = st && st[0] == 'o';
        free(st);
        if (!ok) { *status = 500; return strdup("{\"error\":\"capture failed\"}"); }
        FILE *f = fopen(shot, "rb");
        if (!f) { *status = 500; return strdup("{\"error\":\"no image file\"}"); }
        fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
        if (sz <= 0 || sz > (64 << 20)) { fclose(f); *status = 500; return strdup("{\"error\":\"bad image\"}"); }
        char *buf = (char *)malloc(sz); size_t rd = fread(buf, 1, sz, f); fclose(f);
        *out_len = (int)rd; *out_ctype = "image/png";
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

// Network-driven bitrate adaptation. While a viewer is connected, sample egress
// backpressure every 400ms and steer the encoder (AIMD): on a drop, cut bitrate
// hard and force a keyframe so laggers resync fast; when the send queue fully
// drains, probe the bitrate back up toward the preset ceiling.
static void *adapt_thread(void *unused) {
    int prev_clients = 0;
    for (;;) {
        usleep(400000);
        int has = (gHttp && rctl_http_has_clients(gHttp)) ? 1 : 0;
        if (has && !prev_clients) {   // new viewing session: probe from the ceiling
            pthread_mutex_lock(&gAdaptLock);
            gBitrateCurrent = gBitrateCeiling;
            pthread_mutex_unlock(&gAdaptLock);
        }
        prev_clients = has;
        if (!has) continue;

        int maxq = 0, lagged = 0;
        rctl_http_egress_sample(gHttp, &maxq, &lagged);

        pthread_mutex_lock(&gAdaptLock);
        int ceiling = gBitrateCeiling, cur = gBitrateCurrent, next = cur;
        bool back_off = false;
        if (lagged > 0) {                 // dropping frames -> back off hard
            next = cur * 3 / 5;
            if (next < RCTL_BITRATE_FLOOR) next = RCTL_BITRATE_FLOOR;
            back_off = true;
        } else if (maxq == 0) {           // queue fully drained -> probe up
            next = cur + ceiling / 16;
            if (next > ceiling) next = ceiling;
        }
        gBitrateCurrent = next;
        pthread_mutex_unlock(&gAdaptLock);

        if (next != cur) { int32_t br = next; send_to_sb(RCTL_MSG_BITRATE, &br, sizeof br); }
        if (back_off) send_to_sb(RCTL_MSG_KEYFRAME, NULL, 0);
    }
    return NULL;
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
        // Recompute both capture and keep-awake after a SpringBoard reconnect.
        // This includes WebRTC-only and camera sessions, not just /stream users.
        dispatch_async(gAuto, ^{ apply_active(); });

        uint8_t type; uint8_t *buf; uint32_t len;
        while (rctl_ipc_recv(peer, &type, &buf, &len)) {
            if (type == RCTL_MSG_VIDEO && len >= 9) {
                rctl_http_push_au(gHttp, buf + 9, len - 9, buf[0] != 0, read_be64(buf + 1));
                rctl_webrtc_push_au(buf + 9, len - 9, buf[0] != 0, read_be64(buf + 1));
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

// Renew the audio-capture lease: the in-mediaserverd tap self-disables if its marker
// goes stale (see rctlaudio capture_watchdog), so keep touching it while the user
// wants audio. If rctld dies or audio is turned off, the marker stops refreshing and
// the tap shuts itself down within the lease window -- it never lingers unattended.
static void *audio_lease_thread(void *arg) {
    (void)arg;
    for (;;) {
        sleep(60);
        pthread_mutex_lock(&gAudioCtlLock);
        // utimes() bumps mtime even on an existing file (open(O_CREAT) does NOT), so
        // the rctlaudio lease watchdog sees a fresh marker and keeps capture alive.
        if (gAudioCaptureDesired && utimes(RCTL_AUDIO_CAPTURE_MARKER, NULL) != 0)
            touch_file(RCTL_AUDIO_CAPTURE_MARKER);
        pthread_mutex_unlock(&gAudioCtlLock);
    }
    return NULL;
}

// Activate a Playback audio session so AudioQueue output from this daemon is
// actually routed to the speaker. rctld is a LaunchDaemon (not an app), so it has
// no audio session by default and AudioQueue plays into the void -- this is why the
// mic intercom decoded fine but was silent. Driven via the runtime (AVFoundation
// dlopen'd lazily) so we don't link it. Idempotent; called on the first mic frame.
extern "C" void rctl_audio_session_activate(void) {
    // NOT dispatch_once: the OS can deactivate our session when a WebRTC session
    // tears down or mediaserverd restarts, so we re-assert it every time a new mic
    // queue is created (once per talk session) -- otherwise playback works once and
    // is silent on reconnect.
    @try {
        dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY);
        Class C = NSClassFromString(@"AVAudioSession");
        if (!C) { dlog("AVAudioSession class missing"); return; }
        id sess = ((id (*)(id, SEL))objc_msgSend)((id)C, NSSelectorFromString(@"sharedInstance"));
        if (!sess) return;
        NSError *err = nil;
        // Playback category: audible through the media volume, ignores the mute
        // switch. (PlayAndRecord/DefaultToSpeaker comes with the virtual mic.)
        ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(
            sess, NSSelectorFromString(@"setCategory:error:"), @"AVAudioSessionCategoryPlayback", &err);
        ((BOOL (*)(id, SEL, BOOL, NSError **))objc_msgSend)(
            sess, NSSelectorFromString(@"setActive:error:"), YES, &err);
        dlog("AVAudioSession (re)activated (playback)");
    } @catch (id e) {}
}

// AudioQueue plays through the system media volume, so at min volume the intercom
// is inaudible. Raise the media volume to an audible floor while talking and
// restore the user's level afterwards, via the private AVSystemController (the
// daemon-side way to set system volume on iOS 14). Best-effort: if the private API
// is unavailable it simply falls back to respecting the current volume.
static float g_savedVol = -1.0f;
static id rctl_av_system_controller(void) {
    Class C = NSClassFromString(@"AVSystemController");
    if (!C) {
        dlopen("/System/Library/PrivateFrameworks/Celestial.framework/Celestial", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/MediaServices.framework/MediaServices", RTLD_LAZY);
        C = NSClassFromString(@"AVSystemController");
    }
    if (!C) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)C, NSSelectorFromString(@"sharedAVSystemController"));
}
extern "C" void rctl_audio_boost_begin(void) {
    @try {
        id ctrl = rctl_av_system_controller();
        if (!ctrl) return;
        NSString *cat = @"Audio/Video";
        float cur = -1.0f;
        ((BOOL (*)(id, SEL, float *, NSString *))objc_msgSend)(
            ctrl, NSSelectorFromString(@"getVolume:forCategory:"), &cur, cat);
        if (g_savedVol < 0 && cur >= 0) g_savedVol = cur;   // remember the user's level once
        ((BOOL (*)(id, SEL, float, NSString *))objc_msgSend)(
            ctrl, NSSelectorFromString(@"setVolumeTo:forCategory:"), 0.8f, cat);
        dlog("audio boost: media volume -> 0.8 (was saved)");
    } @catch (id e) {}
}
extern "C" void rctl_audio_boost_end(void) {
    @try {
        if (g_savedVol < 0) return;
        id ctrl = rctl_av_system_controller();
        if (ctrl)
            ((BOOL (*)(id, SEL, float, NSString *))objc_msgSend)(
                ctrl, NSSelectorFromString(@"setVolumeTo:forCategory:"), g_savedVol, @"Audio/Video");
        dlog("audio boost: media volume restored");
        g_savedVol = -1.0f;
    } @catch (id e) {}
}

// ---- Daemon-side mic capture (listen to the room ANYTIME) --------------------
// The app-side tap only sees the mic while some app records it. To listen no matter
// what's on screen, the daemon opens its OWN RemoteIO input and pulls the mic. The
// session is PlayAndRecord + MixWithOthers so a game/YouTube keeps playing. Captured
// PCM feeds the room-mic Opus channel and optional device-side recording.
// mic capture + recording state is declared earlier (before rest_handler).

static void rctl_mic_session_record(void) {
    @try {
        dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY);
        Class C = NSClassFromString(@"AVAudioSession");
        if (!C) return;
        id sess = ((id (*)(id, SEL))objc_msgSend)((id)C, NSSelectorFromString(@"sharedInstance"));
        if (!sess) return;
        NSError *err = nil;
        // PlayAndRecord + MixWithOthers(1) | DefaultToSpeaker(8): capture without
        // ducking/stopping whatever audio the foreground app is playing.
        ((BOOL (*)(id, SEL, id, unsigned long, NSError **))objc_msgSend)(
            sess, NSSelectorFromString(@"setCategory:withOptions:error:"),
            @"AVAudioSessionCategoryPlayAndRecord", (unsigned long)(1 | 8), &err);
        ((BOOL (*)(id, SEL, BOOL, NSError **))objc_msgSend)(
            sess, NSSelectorFromString(@"setActive:error:"), YES, &err);
        dlog("AVAudioSession PlayAndRecord active");
    } @catch (id e) {}
}

static OSStatus rctl_mic_input_cb(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                                  UInt32 bus, UInt32 nframes, AudioBufferList *ioData) {
    (void)ref; (void)ioData;
    if (!g_micUnit || nframes == 0) return noErr;
    int16_t buf[8192];
    UInt32 want = nframes > 8192 ? 8192 : nframes;
    AudioBufferList abl;
    abl.mNumberBuffers = 1;
    abl.mBuffers[0].mNumberChannels = 1;
    abl.mBuffers[0].mDataByteSize = want * 2;
    abl.mBuffers[0].mData = buf;
    OSStatus st = AudioUnitRender(g_micUnit, flags, ts, bus, want, &abl);
    if (st != noErr) {
        static unsigned e = 0;
        if ((++e & 0x3f) == 0) { char l[80]; snprintf(l, sizeof l, "miccap render err %d", (int)st); dlog(l); }
        return st;
    }
    rctl_webrtc_push_mic(buf, (int)want, 1, 48000);   // -> room-mic channel (live listen)
    if (g_recording) {
        pthread_mutex_lock(&g_recLock);
        if (g_recording && g_recFile) {
            AudioBufferList rabl;
            rabl.mNumberBuffers = 1;
            rabl.mBuffers[0].mNumberChannels = 1;
            rabl.mBuffers[0].mDataByteSize = want * 2;
            rabl.mBuffers[0].mData = buf;
            if (ExtAudioFileWriteAsync(g_recFile, want, &rabl) == noErr) g_recFrames += want;
        }
        pthread_mutex_unlock(&g_recLock);
    }
    return noErr;
}

static bool rctl_mic_capture_start(void) {
    if (g_micCapturing) return true;
    rctl_mic_session_record();
    AudioComponentDescription d; memset(&d, 0, sizeof d);
    d.componentType = kAudioUnitType_Output;
    d.componentSubType = kAudioUnitSubType_RemoteIO;
    d.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent comp = AudioComponentFindNext(NULL, &d);
    if (!comp) { dlog("miccap: no RemoteIO component"); return false; }
    if (AudioComponentInstanceNew(comp, &g_micUnit) != noErr || !g_micUnit) { dlog("miccap: instance new failed"); g_micUnit = NULL; return false; }
    UInt32 one = 1, zero = 0;
    AudioUnitSetProperty(g_micUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, sizeof one);
    AudioUnitSetProperty(g_micUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, sizeof zero);
    AudioStreamBasicDescription f; memset(&f, 0, sizeof f);
    f.mSampleRate = 48000; f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    f.mChannelsPerFrame = 1; f.mBitsPerChannel = 16; f.mBytesPerFrame = 2; f.mFramesPerPacket = 1; f.mBytesPerPacket = 2;
    AudioUnitSetProperty(g_micUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &f, sizeof f);
    AURenderCallbackStruct cb; cb.inputProc = rctl_mic_input_cb; cb.inputProcRefCon = NULL;
    AudioUnitSetProperty(g_micUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, sizeof cb);
    OSStatus st = AudioUnitInitialize(g_micUnit);
    if (st != noErr) { char l[80]; snprintf(l, sizeof l, "miccap: init failed %d", (int)st); dlog(l); AudioComponentInstanceDispose(g_micUnit); g_micUnit = NULL; return false; }
    st = AudioOutputUnitStart(g_micUnit);
    if (st != noErr) { char l[80]; snprintf(l, sizeof l, "miccap: start failed %d", (int)st); dlog(l); AudioUnitUninitialize(g_micUnit); AudioComponentInstanceDispose(g_micUnit); g_micUnit = NULL; return false; }
    g_micCapturing = true;
    dlog("miccap: started (daemon RemoteIO input)");
    return true;
}

static void rctl_mic_capture_stop(void) {
    if (!g_micCapturing) return;
    if (g_micUnit) {
        AudioOutputUnitStop(g_micUnit);
        AudioUnitUninitialize(g_micUnit);
        AudioComponentInstanceDispose(g_micUnit);
        g_micUnit = NULL;
    }
    g_micCapturing = false;
    dlog("miccap: stopped");
}

// Capture runs while EITHER the browser is listening OR a recording is armed, so a
// recording keeps going after the listener walks away / the page disconnects.
static void rctl_mic_refresh(void) {
    bool want = g_micListenWant || g_micRecordWant;
    if (want && !g_micCapturing) rctl_mic_capture_start();
    else if (!want && g_micCapturing) rctl_mic_capture_stop();
}

// Record the captured mic to an AAC .m4a via ExtAudioFile: hours fit in tens of MB
// and it plays everywhere. The file finalizes (moov atom) on stop/dispose.
static bool rctl_mic_record_start(void) {
    pthread_mutex_lock(&g_recLock);
    if (g_recording) { pthread_mutex_unlock(&g_recLock); return true; }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)RCTL_MIC_REC_PATH, strlen(RCTL_MIC_REC_PATH), false);
    AudioStreamBasicDescription aac; memset(&aac, 0, sizeof aac);
    aac.mFormatID = kAudioFormatMPEG4AAC; aac.mSampleRate = 48000; aac.mChannelsPerFrame = 1;
    OSStatus st = ExtAudioFileCreateWithURL(url, kAudioFileM4AType, &aac, NULL, kAudioFileFlags_EraseFile, &g_recFile);
    if (url) CFRelease(url);
    if (st != noErr || !g_recFile) { char l[80]; snprintf(l, sizeof l, "micrec: create failed %d", (int)st); dlog(l); g_recFile = NULL; pthread_mutex_unlock(&g_recLock); return false; }
    AudioStreamBasicDescription pcm; memset(&pcm, 0, sizeof pcm);
    pcm.mSampleRate = 48000; pcm.mFormatID = kAudioFormatLinearPCM;
    pcm.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    pcm.mChannelsPerFrame = 1; pcm.mBitsPerChannel = 16; pcm.mBytesPerFrame = 2; pcm.mFramesPerPacket = 1; pcm.mBytesPerPacket = 2;
    st = ExtAudioFileSetProperty(g_recFile, kExtAudioFileProperty_ClientDataFormat, sizeof pcm, &pcm);
    if (st != noErr) { char l[80]; snprintf(l, sizeof l, "micrec: client fmt %d", (int)st); dlog(l); ExtAudioFileDispose(g_recFile); g_recFile = NULL; pthread_mutex_unlock(&g_recLock); return false; }
    ExtAudioFileWriteAsync(g_recFile, 0, NULL);   // prime the async writer thread
    g_recFrames = 0;
    g_recording = true;
    pthread_mutex_unlock(&g_recLock);
    dlog("micrec: started");
    return true;
}

static void rctl_mic_record_stop(void) {
    pthread_mutex_lock(&g_recLock);
    if (g_recording && g_recFile) {
        g_recording = false;
        ExtAudioFileDispose(g_recFile);
        g_recFile = NULL;
        dlog("micrec: stopped");
    }
    pthread_mutex_unlock(&g_recLock);
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
        configure_memory_limit();
        dlog("rctld started");
        rctl_relay_start();

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
        rctl_media_set_delete_callback(delete_media_asset);
        rctl_http_set_rest(gHttp, rest_handler, NULL);
        rctl_http_set_session(gHttp, on_session, NULL);   // wake/idle SB on viewer presence
        rctl_webrtc_set_viewer_cb(on_webrtc_viewers);     // WebRTC viewers keep capture awake too
        rctl_webrtc_set_keyframe_cb(on_webrtc_keyframe_request); // browser PLI -> force a keyframe
        rctl_webrtc_set_camera_keyframe_cb(on_webrtc_camera_keyframe_request);
        rctl_webrtc_set_input_cb(on_webrtc_touch, on_webrtc_key);   // input over the control DataChannel
        rctl_webrtc_set_files_cb(on_files_message);                 // file transfer over the files DataChannel
        dlog("http listening on :8080");
        rctl_camera_set_expired_cb(on_camera_lease_expired);
        if (!rctl_vmic_server_start()) dlog("virtual mic server start FAILED");
        if (!rctl_camera_ingest_start()) dlog("camera ingest start FAILED");
        notify_post("com.greatlove.rctl.cam.sync"); // fail closed after a daemon restart
        audio_capture_set(false, NULL, 0);

        pthread_t t;
        pthread_create(&t, NULL, ipc_thread, NULL);
        pthread_t at;
        pthread_create(&at, NULL, audio_ipc_thread, NULL);
        pthread_t tt;
        pthread_create(&tt, NULL, audio_tcp_thread, NULL);
        pthread_t adt;
        pthread_create(&adt, NULL, adapt_thread, NULL);
        pthread_t alt;
        pthread_create(&alt, NULL, audio_lease_thread, NULL);

        dispatch_main();
    }
    return 0;
}
