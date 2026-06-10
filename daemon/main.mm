// rctld — root daemon, supervised by launchd (RunAtLoad + KeepAlive).
// Hosts the transport (HTTP/WebCodecs today; WebSocket/REST/WebRTC next) and
// relays between browsers and the SpringBoard agent over a local Unix socket:
//   SB -> daemon: encoded H.264 access units + orientation
//   daemon -> SB: touch / key / reconfigure commands
// Keeping transport here means a network bug can't respring SpringBoard, and
// launchd restarts us on any crash.

#import <Foundation/Foundation.h>
#import <pthread.h>
#import <unistd.h>
#import <stdio.h>
#import <time.h>
#import <dlfcn.h>
#import <spawn.h>
#import "net/HttpStreamServer.h"
#import "ipc/Ipc.h"

extern char **environ;
static void respring_device(void) {
    pid_t pid;
    char *argv[] = { (char *)"killall", (char *)"SpringBoard", NULL };
    posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, argv, environ);
}

static void dlog(const char *msg) {
    FILE *f = fopen("/tmp/rctld.log", "a");
    if (f) { fprintf(f, "[%ld pid=%d] %s\n", (long)time(NULL), getpid(), msg); fclose(f); }
}

static rctl_http_server *gHttp = NULL;
static rctl_ipc        *gSB    = NULL;                       // current SB connection
static pthread_mutex_t  gSBLock = PTHREAD_MUTEX_INITIALIZER;

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

static char *rest_handler(void *ctx, const char *path, const char *query, const char *body, int *status) {
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
    } else {
        *status = 404; return strdup("{\"error\":\"unknown action\"}");
    }
    return strdup("{\"ok\":true}");
}

// Accept the SB agent, pump its messages to the HTTP server, re-accept on drop.
static void *ipc_thread(void *unused) {
    rctl_ipc_server *srv = rctl_ipc_listen(RCTL_IPC_SOCK_PATH);
    if (!srv) { dlog("ipc listen FAILED"); return NULL; }
    dlog("ipc listening");
    for (;;) {
        rctl_ipc *peer = rctl_ipc_accept(srv);
        if (!peer) { usleep(100000); continue; }
        dlog("SB connected");
        pthread_mutex_lock(&gSBLock); gSB = peer; pthread_mutex_unlock(&gSBLock);

        uint8_t type; uint8_t *buf; uint32_t len;
        while (rctl_ipc_recv(peer, &type, &buf, &len)) {
            if (type == RCTL_MSG_VIDEO && len >= 1) {
                rctl_http_push_au(gHttp, buf + 1, len - 1, buf[0] != 0);
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
        dlog("http listening on :8080");

        pthread_t t;
        pthread_create(&t, NULL, ipc_thread, NULL);

        dispatch_main();
    }
    return 0;
}
