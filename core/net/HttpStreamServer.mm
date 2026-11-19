// HttpStreamServer.mm — minimal HTTP server that streams H.264 access units to
// browsers, where WebCodecs decodes them. Application framing inside the HTTP
// (chunked) body:
//   [1 byte type][4 byte BE length][type-specific payload].
// Type 0/1 video payload: [8 byte BE pts_us][Annex-B data].
// Type 4 PCM payload: [8 byte BE pts_us][4 byte BE rate][channels][bytes/sample]
//                     [2 byte BE frames][interleaved s16le data].

#import "net/HttpStreamServer.h"
#import "net/HttpHeaders.h"
#import "platform/Paths.h"
#import "net/Term.h"
#import "security/DeviceToken.h"
#import "security/FilePolicy.h"
#import <pthread.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <limits.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>
#import <math.h>
#import <sys/stat.h>
#import <time.h>

#define RCTL_MAX_CLIENTS 8
#define RCTL_MAX_CONNS 32        // concurrent remote connection threads (each ~0.5-1 MB stack)
#define RCTL_MAX_CONNS_TOTAL 64  // including loopback, so Relay-only mode stays bounded too
#define RCTL_SUB_QUEUE_MAX 24      // per-subscriber queued frames before drop-to-latest
#define RCTL_AUDIO_TEST_RATE 48000
#define RCTL_AUDIO_TEST_FRAMES 960
#define RCTL_AUDIO_MAX_CHANNELS 2
#define RCTL_AUDIO_MAX_FRAMES 4096

// One queued, already-framed message for a subscriber.
typedef struct {
    uint8_t *buf;   // HTTP-chunk-framed bytes ready to send (owned)
    size_t   len;
    bool     is_video;
    bool     is_key;
} rctl_frame;

// A /stream subscriber. Sends are non-blocking: the producer enqueues frames
// and opportunistically flushes, so a slow socket only backs up this
// subscriber's bounded queue. On overflow we drop queued video and wait for
// the next keyframe (drop-to-latest) instead of blocking the encoder.
typedef struct {
    int fd;                          // -1 = empty slot
    rctl_frame q[RCTL_SUB_QUEUE_MAX];
    int head, count;
    size_t cur_off;                  // bytes of q[head] already sent
    bool needs_keyframe;             // dropped video; skip deltas until a keyframe
    bool lagging;                    // overflowed at least once (adaptation hint)
} rctl_sub;

struct rctl_http_server {
    int listen_fd;
    int port;
    pthread_t thread;
    pthread_mutex_t mtx;
    rctl_sub subs[RCTL_MAX_CLIENTS]; // stream subscribers (fd < 0 = empty)
    uint8_t *keyframe;
    size_t keyframe_len;
    uint64_t keyframe_pts_us;
    int orientation;
    rctl_reconfigure_cb recfg;
    void *recfg_ctx;
    rctl_input_cb input_cb;
    void *input_ctx;
    rctl_key_cb key_cb;
    void *key_ctx;
    rctl_rest_cb rest_cb;
    void *rest_ctx;
    rctl_session_cb session_cb;
    void *session_ctx;
    pthread_t audio_thread;
    bool audio_thread_started;
    bool audio_test_on;
    int audio_test_hz;
    uint64_t audio_test_pts_us;
    double audio_test_phase;
    bool was_active;               // last-notified state (a /stream client present)
    time_t control_client_log_at;  // rate-limit missing-package diagnostics
    volatile bool running;
    int live_conns;    // concurrent connection threads, total (atomic)
    int live_remote;   // non-loopback connection threads (atomic)
    int live_loopback; // loopback connection threads (atomic)
    bool loopback_only; // Relay-only binding: loopback owns the whole budget
};

// Monotonic seconds for phase deadlines: wall-clock jumps (NTP, manual) must
// not extend or truncate request timeouts.
static double monotonic_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

// Number of live /stream subscribers (caller holds the mutex).
static int count_clients_locked(rctl_http_server *s) {
    int n = 0;
    for (int i = 0; i < RCTL_MAX_CLIENTS; i++) if (s->subs[i].fd >= 0) n++;
    return n;
}

static char *read_file(const char *path, size_t *outLen) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); return NULL; }
    char *b = (char *)malloc((size_t)n + 1);
    if (!b) { fclose(f); return NULL; }
    size_t rd = fread(b, 1, (size_t)n, f);
    fclose(f);
    b[rd] = 0;
    if (outLen) *outLen = rd;
    return b;
}

static void send_data(int fd, const char *status, const char *ctype,
                      const void *body, size_t len, const char *extra = NULL);
static void send_text(int fd, const char *status, const char *ctype, const char *body,
                      const char *extra = NULL);
static bool send_full(int fd, const void *buf, size_t len);

// Redeems the single-use download ticket for this pull_stream request; the
// ticket store lives below with the request gate.
static bool pull_stream_redeem_ticket(const char *request, const char *path, int *fd_out, off_t *size_out);
static void stream_file_download(int fd, const char *request, bool redeem_ticket);

// Extract one URL-encoded parameter value from a bounded query region.
// Decoding lives in HttpHeaders.h (rctl_http_decode_query_value) so the strict
// NUL/escape rules are unit-tested against the ticket and pull_stream
// consumers.
static bool query_param(const char *query, size_t query_len, const char *key, char *out, size_t cap) {
    size_t key_len = strlen(key);
    const char *end = query + query_len;
    const char *p = query;
    while (p < end) {
        const char *amp = (const char *)memchr(p, '&', (size_t)(end - p));
        const char *pair_end = amp ? amp : end;
        size_t pair_len = (size_t)(pair_end - p);
        if (pair_len > key_len && strncmp(p, key, key_len) == 0 && p[key_len] == '=') {
            return rctl_http_decode_query_value(p + key_len + 1, pair_len - key_len - 1, out, cap);
        }
        p = amp ? amp + 1 : end;
    }
    return false;
}

static bool pull_stream_path(const char *request, char *out, size_t out_cap) {
    static const char prefix[] = "GET /v1/pull_stream?";
    if (strncmp(request, prefix, sizeof(prefix) - 1) != 0) return false;
    const char *target_end = strchr(request + sizeof(prefix) - 1, ' ');
    if (!target_end) return false;
    const char *query = request + sizeof(prefix) - 1;
    while (query < target_end) {
        const char *pair_end = (const char *)memchr(query, '&', (size_t)(target_end - query));
        if (!pair_end) pair_end = target_end;
        static const char key[] = "path=";
        if ((size_t)(pair_end - query) >= sizeof(key) - 1 &&
            memcmp(query, key, sizeof(key) - 1) == 0) {
            return rctl_http_decode_query_value(query + sizeof(key) - 1,
                                      (size_t)(pair_end - query - (sizeof(key) - 1)),
                                      out, out_cap);
        }
        query = pair_end + (pair_end < target_end ? 1 : 0);
    }
    return false;
}

static void download_name(const char *path, char *out, size_t out_cap) {    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    size_t oi = 0;
    for (; *base && oi + 1 < out_cap; base++) {
        unsigned char c = (unsigned char)*base;
        out[oi++] = ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                     (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-') ? (char)c : '_';
    }
    if (!oi && out_cap >= 9) { memcpy(out, "download", 8); oi = 8; }
    out[oi] = 0;
}

static void stream_file_download(int fd, const char *request, bool redeem_ticket) {
    char path[1024];
    if (!pull_stream_path(request, path, sizeof(path))) {
        send_text(fd, "400 Bad Request", "application/json", "{\"error\":\"invalid path\"}");
        return;
    }
    // A ticketed download redeems the ticket's OWNED descriptor — the exact
    // object verified at issuance; a rename or replace in between cannot
    // change what is served. A hop download opens fresh under the policy
    // walk (symlinks and hard links refused inside it).
    int file_fd = -1;
    struct stat st;
    if (redeem_ticket) {
        off_t verified_size = -1;
        if (!pull_stream_redeem_ticket(request, path, &file_fd, &verified_size) ||
            fstat(file_fd, &st) != 0 || st.st_size != verified_size) {
            if (file_fd >= 0) close(file_fd);
            send_text(fd, "403 Forbidden", "application/json", "{\"error\":\"invalid ticket\"}");
            return;
        }
    } else {
        if (!rctl_file_policy_open_read(path, &file_fd)) {
            send_text(fd, "403 Forbidden", "application/json", "{\"error\":\"protected_path\"}");
            return;
        }
        if (fstat(file_fd, &st) != 0) {
            close(file_fd);
            send_text(fd, "403 Forbidden", "application/json", "{\"error\":\"cannot open\"}");
            return;
        }
    }
    if (st.st_size < 0) {
        close(file_fd);
        send_text(fd, "400 Bad Request", "application/json", "{\"error\":\"bad size\"}");
        return;
    }

    char name[192];
    download_name(path, name, sizeof(name));
    uint8_t *buffer = (uint8_t *)malloc(64 * 1024);
    if (!buffer) {
        close(file_fd);
        send_text(fd, "500 Internal Server Error", "application/json", "{\"error\":\"out of memory\"}");
        return;
    }
    struct timeval timeout = { 30, 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    char header[896];
    int header_len = snprintf(header, sizeof(header),
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
        "Content-Disposition: attachment; filename=\"%s\"\r\n"
        "Content-Length: %lld\r\nCache-Control: no-store\r\n"
        "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        "Connection: close\r\n\r\n", name, (long long)st.st_size);
    if (header_len <= 0 || header_len >= (int)sizeof(header) ||
        !send_full(fd, header, (size_t)header_len)) {
        free(buffer);
        close(file_fd);
        return;
    }
    for (;;) {
        ssize_t count = read(file_fd, buffer, 64 * 1024);
        if (count == 0) break;
        if (count < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (!send_full(fd, buffer, (size_t)count)) break;
    }
    free(buffer);
    close(file_fd);
}

static bool send_full(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t w = send(fd, p + off, len - off, MSG_NOSIGNAL);
        if (w <= 0) { if (w < 0 && errno == EINTR) continue; return false; }
        off += (size_t)w;
    }
    return true;
}

static const char *ctype_for_path(const char *path) {
    const char *dot = strrchr(path, '.');
    if (!dot) return "application/octet-stream";
    if (!strcmp(dot, ".js")) return "application/javascript; charset=utf-8";
    if (!strcmp(dot, ".css")) return "text/css; charset=utf-8";
    if (!strcmp(dot, ".html")) return "text/html; charset=utf-8";
    return "application/octet-stream";
}

// Send one access unit as a single HTTP chunk: "<hex>\r\n" + appframe + "\r\n".
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

static void put_le16(uint8_t *p, int16_t v) {
    p[0] = (uint8_t)(v & 0xff);
    p[1] = (uint8_t)(((uint16_t)v >> 8) & 0xff);
}

// Build one HTTP chunk ("<hex>\r\n" + appframe + "\r\n") into a malloc'd buffer.
static uint8_t *build_frame_chunk(uint8_t type, const uint8_t *data, size_t len, size_t *out_total) {
    char hdr[32];
    size_t af_len = 5 + len;
    int hl = snprintf(hdr, sizeof(hdr), "%zx\r\n", af_len);
    size_t total = (size_t)hl + af_len + 2;
    uint8_t *b = (uint8_t *)malloc(total);
    if (!b) return NULL;
    memcpy(b, hdr, hl);
    uint8_t *af = b + hl;
    af[0] = type;
    af[1] = (len >> 24) & 0xff; af[2] = (len >> 16) & 0xff;
    af[3] = (len >> 8) & 0xff;  af[4] = len & 0xff;
    if (len) memcpy(af + 5, data, len);
    b[total - 2] = '\r'; b[total - 1] = '\n';
    *out_total = total;
    return b;
}

static uint8_t *build_video_chunk(uint8_t type, uint64_t pts_us, const uint8_t *data, size_t len, size_t *out_total) {
    if (len > UINT32_MAX - 8 || len > SIZE_MAX - 13) return NULL;
    char hdr[32];
    size_t af_len = 5 + 8 + len;
    int hl = snprintf(hdr, sizeof(hdr), "%zx\r\n", af_len);
    size_t total = (size_t)hl + af_len + 2;
    uint8_t *b = (uint8_t *)malloc(total);
    if (!b) return NULL;
    memcpy(b, hdr, hl);
    uint8_t *af = b + hl;
    af[0] = type;
    size_t payload_len = 8 + len;
    af[1] = (payload_len >> 24) & 0xff; af[2] = (payload_len >> 16) & 0xff;
    af[3] = (payload_len >> 8) & 0xff;  af[4] = payload_len & 0xff;
    put_be64(af + 5, pts_us);
    if (len) memcpy(af + 13, data, len);
    b[total - 2] = '\r'; b[total - 1] = '\n';
    *out_total = total;
    return b;
}

static void sub_set_nonblock(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

// Free every queued frame and reset the queue (caller holds the server mutex).
static void sub_clear(rctl_sub *sub) {
    for (int i = 0; i < sub->count; i++) free(sub->q[(sub->head + i) % RCTL_SUB_QUEUE_MAX].buf);
    sub->head = sub->count = 0;
    sub->cur_off = 0;
}

// Drop queued video frames after backpressure, keeping control/audio so the
// stream resyncs cleanly at the next keyframe instead of showing a gap.
static void sub_drop_video(rctl_sub *sub) {
    rctl_frame keep[RCTL_SUB_QUEUE_MAX];
    int kn = 0;
    bool head_kept = false;
    for (int i = 0; i < sub->count; i++) {
        rctl_frame f = sub->q[(sub->head + i) % RCTL_SUB_QUEUE_MAX];
        if (f.is_video) { free(f.buf); continue; }
        if (i == 0) head_kept = true;     // the partially-sent head survived
        keep[kn++] = f;
    }
    if (!head_kept) sub->cur_off = 0;     // head dropped; restart at next frame
    for (int i = 0; i < kn; i++) sub->q[i] = keep[i];
    sub->head = 0;
    sub->count = kn;
}

// Enqueue an owned, framed buffer, applying drop-to-latest on overflow.
static void sub_enqueue(rctl_sub *sub, uint8_t *buf, size_t len, bool is_video, bool is_key) {
    if (!buf) return;
    if (is_video && !is_key && sub->needs_keyframe) { free(buf); return; } // awaiting resync
    if (sub->count >= RCTL_SUB_QUEUE_MAX) {
        sub_drop_video(sub);
        sub->needs_keyframe = true;
        sub->lagging = true;
        if (is_video && !is_key) { free(buf); return; }   // don't queue the stale delta
        if (sub->count >= RCTL_SUB_QUEUE_MAX) {            // still full (control only): drop oldest
            free(sub->q[sub->head].buf);
            sub->head = (sub->head + 1) % RCTL_SUB_QUEUE_MAX;
            sub->count--;
            sub->cur_off = 0;
        }
    }
    rctl_frame *slot = &sub->q[(sub->head + sub->count) % RCTL_SUB_QUEUE_MAX];
    slot->buf = buf; slot->len = len; slot->is_video = is_video; slot->is_key = is_key;
    sub->count++;
    if (is_video && is_key) sub->needs_keyframe = false;
}

// Flush as much of the queue as the socket accepts without blocking.
// Returns false if the socket errored (subscriber is dead).
static bool sub_flush(rctl_sub *sub) {
    while (sub->count > 0) {
        rctl_frame *f = &sub->q[sub->head];
        ssize_t w = send(sub->fd, f->buf + sub->cur_off, f->len - sub->cur_off, MSG_NOSIGNAL);
        if (w > 0) {
            sub->cur_off += (size_t)w;
            if (sub->cur_off >= f->len) {
                free(f->buf);
                sub->head = (sub->head + 1) % RCTL_SUB_QUEUE_MAX;
                sub->count--;
                sub->cur_off = 0;
            }
            continue;
        }
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return true; // socket full; later
        if (w < 0 && errno == EINTR) continue;
        return false; // EPIPE / ECONNRESET / etc — dead
    }
    return true;
}

// Close and reset a subscriber slot (caller holds the server mutex).
static void sub_close(rctl_sub *sub) {
    if (sub->fd >= 0) close(sub->fd);
    sub_clear(sub);
    sub->fd = -1;
    sub->needs_keyframe = false;
    sub->lagging = false;
}

static void broadcast_locked(rctl_http_server *s, uint8_t type, const uint8_t *data, size_t len);

static void *audio_test_loop(void *arg) {
    rctl_http_server *s = (rctl_http_server *)arg;
    int16_t samples[RCTL_AUDIO_TEST_FRAMES];
    while (s->running) {
        bool on = false;
        int hz = 440;
        uint64_t pts_us = 0;
        double phase = 0;
        pthread_mutex_lock(&s->mtx);
        if (s->audio_test_on && count_clients_locked(s) > 0) {
            on = true;
            hz = s->audio_test_hz;
            pts_us = s->audio_test_pts_us;
            phase = s->audio_test_phase;
        }
        pthread_mutex_unlock(&s->mtx);

        if (on) {
            double inc = (double)hz / (double)RCTL_AUDIO_TEST_RATE;
            for (int i = 0; i < RCTL_AUDIO_TEST_FRAMES; i++) {
                samples[i] = (int16_t)(sin(phase * 2.0 * M_PI) * 4200.0);
                phase += inc;
                if (phase >= 1.0) phase -= 1.0;
            }
            pthread_mutex_lock(&s->mtx);
            if (s->audio_test_on) {
                s->audio_test_phase = phase;
                s->audio_test_pts_us = pts_us + 20000;
            }
            pthread_mutex_unlock(&s->mtx);
            rctl_http_push_pcm_s16le(s, samples, RCTL_AUDIO_TEST_FRAMES, 1,
                                     RCTL_AUDIO_TEST_RATE, pts_us);
        }
        usleep(20000);
    }
    return NULL;
}

static void send_data(int fd, const char *status, const char *ctype,
                      const void *body, size_t len, const char *extra) {
    // Ship the same security headers the relay sets on the control page, so the
    // device-served (LAN) page isn't a weaker origin: a strict CSP (frame-ancestors
    // none, no eval, https-only images), nosniff, and no referrer leakage. The CSP
    // is ignored on non-document responses (the /v1 JSON) but nosniff still helps.
    char hdr[768];
    int n = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
        "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        "%s"
        "Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; "
        "style-src 'self' 'unsafe-inline'; font-src 'self' data:; connect-src 'self' ws: wss: stun: turn: turns:; "
        "img-src 'self' data: blob: https:; media-src 'self' blob:; frame-ancestors 'none'; "
        "base-uri 'none'; form-action 'self'\r\n"
        "Connection: close\r\n\r\n",
        status, ctype, len, extra ? extra : "");
    if (n < 0 || n >= (int)sizeof(hdr)) return;   // header overflow: drop, don't send garbage
    send_full(fd, hdr, n);
    send_full(fd, body, len);
}
static void send_text(int fd, const char *status, const char *ctype, const char *body,
                      const char *extra) {
    send_data(fd, status, ctype, body, strlen(body), extra);
}

static void log_control_client_unavailable(rctl_http_server *s) {
    time_t now = time(NULL);
    bool should_log = false;
    pthread_mutex_lock(&s->mtx);
    if (s->control_client_log_at == 0 || now < s->control_client_log_at ||
        now - s->control_client_log_at >= 60) {
        s->control_client_log_at = now;
        should_log = true;
    }
    pthread_mutex_unlock(&s->mtx);
    if (should_log) {
        fprintf(stderr, "[http] control client unavailable: required file "
                        "%s is missing, empty, or unreadable\n", RCTL_WEB_CLIENT);
    }
}

// One connection per thread so a slow request (e.g. /v1/camera waiting for the
// in-app capturer to POST its photo back) can't block other requests.
// ── request gate ────────────────────────────────────────────────────────────
//
// Every request passes one gate before dispatch. The gate validates the
// request line (origin-form target, known method), requires a single Host
// field naming the address the connection actually terminated on — a rebound
// DNS name keeps the attacker's name in Host, so this defeats rebinding — and
// enforces the LAN token policy. Without a valid token only these proceed:
// the static page, the header-gated bootstrap, the legacy loopback health
// probes, the camera IPC routes, relay-hop-authenticated tunnel requests, and
// one-time ticketed downloads. Relay-only mode disables direct control
// entirely: only probes and the authenticated relay hop work there.
//
// The camera IPC header and the relay-hop credential both act as browser
// barriers — a cross-origin page can neither set a custom header (no CORS
// permission is granted) nor offer a WebSocket subprotocol the gate accepts —
// while the hop credential additionally authenticates rctld's own loopback
// consumers to each other.

#define RCTL_CAMERA_IPC_HEADER "X-Rctl-Camera-Ipc"
#define RCTL_CAMERA_IPC_VALUE "1"
#define RCTL_BOOTSTRAP_HEADER "X-Rctl-Bootstrap"
#define RCTL_BOOTSTRAP_VALUE "1"
#define RCTL_RELAY_HOP_HEADER "X-Rctl-Relay-Hop"
#define RCTL_TOKEN_HEADER "X-Rctl-Token"
#define RCTL_WS_PROTO_PREFIX "rctl.auth."

enum {
    GATE_OPEN,      // proceed to dispatch (possibly with probe flag)
    GATE_WS,        // proceed; ws_proto holds the exact subprotocol to echo
    GATE_HANDLED,   // gate answered and closed the request itself
    GATE_DENY,      // 403 sent; caller just closes
};

// One-time download tickets: the browser's <a> download cannot attach the
// token header, so /v1/pull_stream redeems a short-lived ticket issued for one
// exact path. Bounded store; expired and used slots are reused.
#define RCTL_TICKET_BYTES 16
#define RCTL_TICKETS 8
#define RCTL_TICKET_TTL 60.0
typedef struct {
    char id[RCTL_TICKET_BYTES * 2 + 1];
    char path[1024];
    double expires;
    bool used;
    int fd;        // the verified, still-open object; -1 when empty
    off_t size;    // verified size at issuance
} rctl_ticket;
static rctl_ticket g_tickets[RCTL_TICKETS];
static pthread_mutex_t g_ticket_mtx = PTHREAD_MUTEX_INITIALIZER;
static bool g_ticket_store_open = true;

static void ticket_store_init(void) {
    g_ticket_store_open = true;
    for (int i = 0; i < RCTL_TICKETS; i++) g_tickets[i].fd = -1;
}

// Once closed, no in-flight issuer may insert a ticket after the final sweep:
// admission and the sweep share the store mutex, and the closed flag is read
// under it.
static void ticket_store_shutdown(void) {
    pthread_mutex_lock(&g_ticket_mtx);
    g_ticket_store_open = false;
    for (int i = 0; i < RCTL_TICKETS; i++) {
        if (g_tickets[i].fd >= 0) { close(g_tickets[i].fd); g_tickets[i].fd = -1; }
        g_tickets[i].path[0] = 0;
        g_tickets[i].used = false;
        g_tickets[i].expires = 0;
    }
    pthread_mutex_unlock(&g_ticket_mtx);
}

static bool fd_local_addrs(int fd, bool *src_loopback, bool *dst_loopback,
                           uint32_t *local_addr, uint16_t *local_port) {
    struct sockaddr_in sa; socklen_t sl = sizeof(sa);
    if (getpeername(fd, (struct sockaddr *)&sa, &sl) != 0) return false;
    *src_loopback = sa.sin_family == AF_INET && ntohl(sa.sin_addr.s_addr) == INADDR_LOOPBACK;
    sl = sizeof(sa);
    if (getsockname(fd, (struct sockaddr *)&sa, &sl) != 0) return false;
    if (sa.sin_family != AF_INET) return false;
    *dst_loopback = ntohl(sa.sin_addr.s_addr) == INADDR_LOOPBACK;
    *local_addr = ntohl(sa.sin_addr.s_addr);
    *local_port = ntohs(sa.sin_port);
    return true;
}

// Host must name the address this connection terminated on (or the canonical
// loopback names on a loopback destination) and the listening port. Names are
// rejected outright: a rebound DNS lookup cannot pass, and no mDNS alias
// grants the direct authority.
static bool host_allowed(const char *host_value, bool dst_loopback,
                         uint32_t local_addr, uint16_t listen_port) {
    char host[256]; int port = 0;
    if (!rctl_http_split_authority(host_value, host, sizeof(host), &port)) return false;
    if (!strcmp(host, "localhost") || !strcmp(host, "127.0.0.1")) return dst_loopback;
    struct in_addr parsed;
    if (inet_pton(AF_INET, host, &parsed) != 1) return false;
    if (ntohl(parsed.s_addr) != local_addr) return false;
    return port == (int)listen_port;
}

static void deny_json(int fd, const char *status, const char *code) {
    send_text(fd, status, "application/json", code);
}

// Close an expired or superseded slot's owned descriptor and release it.
// Called with the store mutex held.
static void ticket_slot_release_locked(rctl_ticket *t) {
    if (t->fd >= 0) { close(t->fd); t->fd = -1; }
    t->path[0] = 0;
    t->used = false;
    t->expires = 0;
}

// Issue a ticket that OWNS the verified object descriptor: the file is
// checked and opened at issuance and redemption serves that exact fd, so a
// rename, replace, or delete in between cannot change what is served (and a
// vanished file cannot strand the anchor — the download succeeds from the
// pinned object). Bounded: a full store answers 503.
static bool ticket_issue(int verified_fd, const char *path, char *out, size_t out_cap) {
    bool ok = false;
    pthread_mutex_lock(&g_ticket_mtx);
    if (!g_ticket_store_open) {   // shutdown raced an in-flight issuer
        pthread_mutex_unlock(&g_ticket_mtx);
        return false;             // the caller retains (and closes) the fd
    }
    int slot = -1;
    double now = monotonic_seconds();
    for (int i = 0; i < RCTL_TICKETS && slot < 0; i++) {
        if (g_tickets[i].path[0] == 0) {
            if (g_tickets[i].fd >= 0) { close(g_tickets[i].fd); g_tickets[i].fd = -1; }
            slot = i;
        } else if (g_tickets[i].used || g_tickets[i].expires < now) {
            ticket_slot_release_locked(&g_tickets[i]);
            slot = i;
        }
    }
    if (slot >= 0) {
        uint8_t raw[RCTL_TICKET_BYTES];
        arc4random_buf(raw, sizeof(raw));
        static const char digits[] = "0123456789abcdef";
        for (size_t i = 0; i < sizeof(raw); i++) {
            g_tickets[slot].id[i * 2] = digits[raw[i] >> 4];
            g_tickets[slot].id[i * 2 + 1] = digits[raw[i] & 0xF];
        }
        g_tickets[slot].id[sizeof(raw) * 2] = 0;
        snprintf(g_tickets[slot].path, sizeof(g_tickets[slot].path), "%s", path);
        g_tickets[slot].expires = now + RCTL_TICKET_TTL;
        g_tickets[slot].used = false;
        g_tickets[slot].fd = verified_fd;   // ownership moves here
        struct stat st = {};
        g_tickets[slot].size = fstat(verified_fd, &st) == 0 ? st.st_size : -1;
        snprintf(out, out_cap, "%s", g_tickets[slot].id);
        ok = true;
    }
    pthread_mutex_unlock(&g_ticket_mtx);
    return ok;
}

// Validate without consuming: the download must still claim the owned
// descriptor before the single-use redemption happens.
static bool ticket_validate(const char *id, const char *path) {
    if (!id || !path) return false;
    bool ok = false;
    pthread_mutex_lock(&g_ticket_mtx);
    double now = monotonic_seconds();
    for (int i = 0; i < RCTL_TICKETS; i++) {
        rctl_ticket *t = &g_tickets[i];
        if (t->path[0] == 0) { ticket_slot_release_locked(t); continue; }
        if (t->used || t->expires < now) { ticket_slot_release_locked(t); continue; }
        if (strcmp(t->id, id) == 0 && strcmp(t->path, path) == 0) { ok = true; break; }
    }
    pthread_mutex_unlock(&g_ticket_mtx);
    return ok;
}

// Single atomic redemption: one matching request takes over the owned
// descriptor (the caller closes it after streaming), replays and a changed
// path fail. A reclaimable slot's fd is closed on expiry.
static bool ticket_redeem(const char *id, const char *path, int *fd_out, off_t *size_out) {
    if (!id || !path || !fd_out || !size_out) return false;
    bool ok = false;
    pthread_mutex_lock(&g_ticket_mtx);
    double now = monotonic_seconds();
    for (int i = 0; i < RCTL_TICKETS; i++) {
        rctl_ticket *t = &g_tickets[i];
        if (t->path[0] == 0) { ticket_slot_release_locked(t); continue; }
        if (t->used || t->expires < now) { ticket_slot_release_locked(t); continue; }
        if (strcmp(t->id, id) == 0 && strcmp(t->path, path) == 0) {
            t->used = true;
            *fd_out = t->fd;
            *size_out = t->size;
            t->fd = -1;
            ok = true;
            break;
        }
    }
    pthread_mutex_unlock(&g_ticket_mtx);
    return ok;
}

// Pull the ticket from the pull_stream query and redeem it against the exact
// path the download is about to serve; the owned descriptor moves to the
// caller.
static bool pull_stream_redeem_ticket(const char *request, const char *path, int *fd_out, off_t *size_out) {
    const char *query = strchr(request, '?');
    if (!query) return false;
    ++query;
    const char *target_end = strchr(query, ' ');
    if (!target_end) return false;
    size_t query_len = (size_t)(target_end - query);
    char ticket[128];
    if (!query_param(query, query_len, "ticket", ticket, sizeof(ticket))) return false;
    return ticket_redeem(ticket, path, fd_out, size_out);
}

// Copy one field value into a bounded buffer. The CRLF-based lookup in
// HttpHeaders.h returns a pointer that is NOT NUL-terminated — the field's
// own line break is the only bound — and hdr_end is the CR that STARTS the
// terminator's CRLF, i.e. the last field's own terminating CR, so the search
// window must include it.
static bool copy_header_value(const char *req, const char *hdr_end, const char *name,
                              char *out, size_t cap) {
    const char *v = rctl_http_header(req, hdr_end, name);
    if (!v || v > hdr_end) return false;
    const char *eol = (const char *)memchr(v, '\r', (size_t)(hdr_end - v) + 1);
    if (!eol) return false;
    while (v < eol && (*v == ' ' || *v == '\t')) v++;
    while (eol > v && (eol[-1] == ' ' || eol[-1] == '\t')) eol--;
    size_t len = (size_t)(eol - v);
    if (len >= cap) return false;
    memcpy(out, v, len);
    out[len] = 0;
    return true;
}

static bool header_is(const char *req, const char *hdr_end, const char *name, const char *value) {
    char got[256];
    return copy_header_value(req, hdr_end, name, got, sizeof(got)) &&
           strcasecmp(got, value) == 0;
}

static bool request_is_ws_upgrade(const char *req, const char *hdr_end) {
    char upgrade[64];
    return copy_header_value(req, hdr_end, "Upgrade", upgrade, sizeof(upgrade)) &&
           strcasestr(upgrade, "websocket") != NULL;
}

// The browser offers its token as a WebSocket subprotocol (browsers cannot set
// custom headers on WebSocket). Exactly one protocol may be offered and it
// must carry the valid token; the handler echoes the offered value verbatim.
static bool ws_subprotocol_token(const char *req, const char *hdr_end,
                                 char *out, size_t out_cap) {
    int count = rctl_http_header_count(req, hdr_end, "Sec-WebSocket-Protocol");
    if (count == 0) return true;                   // native/relay clients offer none
    if (count != 1) return false;                  // ambiguous
    char value[256];
    if (!copy_header_value(req, hdr_end, "Sec-WebSocket-Protocol", value, sizeof(value))) return false;
    if (strchr(value, ',')) return false;          // multiple offers: ambiguous
    size_t prefix = sizeof(RCTL_WS_PROTO_PREFIX) - 1;
    if (strncmp(value, RCTL_WS_PROTO_PREFIX, prefix) != 0) return false;
    if (!rctl_device_token_matches(value + prefix)) return false;
    snprintf(out, out_cap, "%s", value);
    return true;
}

// Answer GET /v1/bootstrap for requests that carry the custom bootstrap
// header — a barrier no cross-origin browser page can pass without a CORS
// preflight, and no CORS preflight is ever granted here. Native programs and
// scripts are not drive-by origins and may present it freely. An Origin or
// Sec-Fetch-Site that contradicts the validated Host authority fails closed.
static void serve_bootstrap(int fd, const char *req, const char *hdr_end, const char *host_value) {
    const char *code = NULL;
    if (!header_is(req, hdr_end, RCTL_BOOTSTRAP_HEADER, RCTL_BOOTSTRAP_VALUE)) {
        code = "{\"error\":\"bootstrap_header_required\"}";
    } else {
        char origin[256], site[32];
        bool origin_present = rctl_http_header_count(req, hdr_end, "Origin") > 0;
        if ((origin_present && !copy_header_value(req, hdr_end, "Origin", origin, sizeof(origin))) ||
            (origin_present && !rctl_http_origin_matches(origin, host_value))) {
            code = "{\"error\":\"origin_mismatch\"}";
        } else if (copy_header_value(req, hdr_end, "Sec-Fetch-Site", site, sizeof(site)) &&
                   strcasecmp(site, "same-origin") != 0 && strcasecmp(site, "none") != 0) {
            code = "{\"error\":\"origin_mismatch\"}";
        }
    }
    const char *token = rctl_device_token();
    if (!code && !token) code = "{\"error\":\"gateway_unready\"}";
    if (code) {
        deny_json(fd, "403 Forbidden", code);
        return;
    }
    char body[128];
    snprintf(body, sizeof(body), "{\"token\":\"%s\"}", token);
    send_text(fd, "200 OK", "application/json", body,
              "Cache-Control: private, no-store\r\nCross-Origin-Resource-Policy: same-origin\r\n");
}

// Read the small JSON body of POST /v1/download_ticket directly: bounded
// length, bounded deadline, no upload-budget machinery needed.
static bool read_small_body(int fd, const char *first, size_t have, size_t clen,
                            char *out, size_t cap) {
    if (clen == 0 || clen >= cap) return false;
    size_t got = have < clen ? have : clen;
    memcpy(out, first, got);
    struct timeval tv = { 1, 0 };
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) != 0) return false;
    const double deadline = monotonic_seconds() + 5;
    while (got < clen) {
        if (monotonic_seconds() > deadline) break;
        ssize_t k = recv(fd, out + got, clen - got, 0);
        if (k < 0 && errno == EINTR) continue;
        if (k < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (k <= 0) break;
        got += (size_t)k;
    }
    memset(&tv, 0, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    if (got < clen) return false;
    out[got] = 0;
    return true;
}

// The gate. Order matters: syntax and Host first, then the closed exception
// sets, then the token requirement for everything that remains.
static int request_gate(rctl_http_server *s, int fd, char *req, ssize_t n, char *hdr_end,
                        bool *probe_out, bool *ticket_out, char *ws_proto_out, size_t ws_proto_cap) {
    *probe_out = false;
    *ticket_out = false;
    ws_proto_out[0] = 0;

    // Field syntax must agree with the CRLF-based lookups used below: a bare
    // CR or LF can never smuggle a field past the gate or dispatch.
    if (!rctl_http_fields_valid(req, hdr_end)) {
        deny_json(fd, "400 Bad Request", "{\"error\":\"malformed_header_field\"}");
        return GATE_DENY;
    }

    // Request line: METHOD SP target SP HTTP/1.x, target in origin form. The
    // buffer is NOT mutated — every later lookup is strstr-based over the full
    // request — so the query region is parsed with explicit bounds instead.
    char *line_end = strstr(req, "\r\n");
    if (!line_end || line_end > hdr_end) {
        deny_json(fd, "400 Bad Request", "{\"error\":\"bad_request_line\"}");
        return GATE_DENY;
    }
    char method[8];
    char *target = NULL; char *version = NULL;
    {
        size_t mi = 0;
        char *p = req;
        while (*p && *p != ' ' && mi + 1 < sizeof(method)) method[mi++] = *p++;
        method[mi] = 0;
        if (*p != ' ') { deny_json(fd, "400 Bad Request", "{\"error\":\"bad_request_line\"}"); return GATE_DENY; }
        target = p + 1;
        version = strchr(target, ' ');
        if (!version || version > line_end || version == target) {
            deny_json(fd, "400 Bad Request", "{\"error\":\"bad_request_line\"}");
            return GATE_DENY;
        }
        if (strncmp(version + 1, "HTTP/1.", 7) != 0) {
            deny_json(fd, "400 Bad Request", "{\"error\":\"bad_request_line\"}");
            return GATE_DENY;
        }
        if (target[0] != '/') {   // absolute-form or CONNECT-style targets
            deny_json(fd, "400 Bad Request", "{\"error\":\"origin_form_required\"}");
            return GATE_DENY;
        }
    }
    bool is_get = !strcmp(method, "GET");
    bool is_post = !strcmp(method, "POST");
    if (!is_get && !is_post) {
        deny_json(fd, "405 Method Not Allowed", "{\"error\":\"method_not_allowed\"}");
        return GATE_DENY;
    }

    // Single Host naming the local socket address the request arrived on.
    char host_buf[256];
    if (rctl_http_header_count(req, hdr_end, "Host") != 1 ||
        !copy_header_value(req, hdr_end, "Host", host_buf, sizeof(host_buf))) {
        deny_json(fd, "400 Bad Request", "{\"error\":\"host_required\"}");
        return GATE_DENY;
    }
    bool src_loopback = false, dst_loopback = false;
    uint32_t local_addr = 0; uint16_t local_port = 0;
    if (!fd_local_addrs(fd, &src_loopback, &dst_loopback, &local_addr, &local_port) ||
        !host_allowed(host_buf, dst_loopback, local_addr, (uint16_t)s->port)) {
        deny_json(fd, "400 Bad Request", "{\"error\":\"bad_host\"}");
        return GATE_DENY;
    }

    // Path and query for gate decisions (dispatch re-derives its own view of
    // the request line, which the origin-form check above pinned down).
    size_t target_len = (size_t)(version - target);
    char path[1024];
    const char *query = "";
    size_t query_len = 0;
    {
        const char *qm = (const char *)memchr(target, '?', target_len);
        size_t path_len = qm ? (size_t)(qm - target) : target_len;
        if (path_len == 0 || path_len >= sizeof(path)) {
            deny_json(fd, "400 Bad Request", "{\"error\":\"bad_target\"}");
            return GATE_DENY;
        }
        memcpy(path, target, path_len);
        path[path_len] = 0;
        if (qm) { query = qm + 1; query_len = target_len - path_len - 1; }
    }
    // Camera IPC routes are reserved for the on-device agents: loopback source
    // and destination, the dedicated header, and never the relay hop. They sit
    // before the mode policy because the camera feature must keep working in
    // Relay-only mode.
    static const char *const kCameraIpc[] = {
        "/v1/cam_agent_state", "/v1/cam_upload",
        "/v1/guest_camera_ticket", "/v1/guest_camera_upload", "/v1/guest_camera_stopped",
    };
    for (size_t i = 0; i < sizeof(kCameraIpc) / sizeof(kCameraIpc[0]); i++) {
        if (!strcmp(path, kCameraIpc[i])) {
            bool hop_here = rctl_http_header_count(req, hdr_end, RCTL_RELAY_HOP_HEADER) > 0;
            if (src_loopback && dst_loopback && !hop_here &&
                header_is(req, hdr_end, RCTL_CAMERA_IPC_HEADER, RCTL_CAMERA_IPC_VALUE)) {
                return GATE_OPEN;
            }
            deny_json(fd, "403 Forbidden", "{\"error\":\"camera_ipc_only\"}");
            return GATE_DENY;
        }
    }

    // The relay hop is checked before the policy branches: it authenticates
    // rctld's own loopback consumers, but the camera routes above deliberately
    // reject it, and Relay-only mode below uses it as its only key.
    char hop_buf[80];
    bool hop_present = rctl_http_header_count(req, hdr_end, RCTL_RELAY_HOP_HEADER) > 0;
    bool hop_ok = hop_present && copy_header_value(req, hdr_end, RCTL_RELAY_HOP_HEADER, hop_buf, sizeof(hop_buf)) &&
                  rctl_relay_hop_matches(hop_buf);

    // Legacy loopback probes: updater verifyRuntime and the deploy script —
    // callers that hold no credential at all. Both socket endpoints must be
    // loopback, exact GET, exact path, no query, no upgrade; responses are
    // marked so the REST layer trims sensitive data. A hop-authenticated
    // caller reaches the same paths through the full authorization below.
    static const char *const kProbes[] = { "/v1/capabilities", "/v1/deviceinfo", "/v1/relay_status" };
    if (is_get && !hop_present &&
        rctl_http_header_count(req, hdr_end, RCTL_TOKEN_HEADER) == 0 &&
        src_loopback && dst_loopback && query_len == 0 &&
        !memchr(target, '?', target_len) && !request_is_ws_upgrade(req, hdr_end)) {
        for (size_t i = 0; i < sizeof(kProbes) / sizeof(kProbes[0]); i++) {
            if (!strcmp(path, kProbes[i])) {
                *probe_out = true;
                return GATE_OPEN;
            }
        }
    }

    // Relay-only mode: no direct control, ever — not even over a loopback
    // connection that already holds a token. A hop-authenticated request
    // continues through the normal branches below, where bootstrap, ticket
    // issuance, and the static page are refused to it.
    if (s->loopback_only && !hop_ok) {
        deny_json(fd, "403 Forbidden", "{\"error\":\"relay_only\"}");
        return GATE_DENY;
    }

    char token_buf[80];
    bool token_present = copy_header_value(req, hdr_end, RCTL_TOKEN_HEADER, token_buf, sizeof(token_buf));
    bool token_ok = token_present && rctl_device_token_matches(token_buf);

    // Bootstrap: the token's only delivery channel. The relay hop must never
    // pull it, and Relay-only mode has no direct-control surface to serve.
    if (!strcmp(path, "/v1/bootstrap")) {
        if (!is_get) {
            deny_json(fd, "405 Method Not Allowed", "{\"error\":\"use_get\"}");
            return GATE_DENY;
        }
        if (s->loopback_only || hop_ok) {
            deny_json(fd, "403 Forbidden", s->loopback_only ? "{\"error\":\"relay_only\"}"
                                                            : "{\"error\":\"bootstrap_not_over_tunnel\"}");
            return GATE_DENY;
        }
        serve_bootstrap(fd, req, hdr_end, host_buf);
        return GATE_HANDLED;
    }

    // One-time download ticket issuance: only the full LAN token converts a
    // path into a short-lived ticket; the relay hop downloads through the
    // stream tunnel directly and never needs one.
    if (is_post && !strcmp(path, "/v1/download_ticket")) {
        if (!token_ok) {
            deny_json(fd, "403 Forbidden",
                      token_present ? "{\"error\":\"lan_token_invalid\"}"
                                    : "{\"error\":\"lan_token_required\"}");
            return GATE_DENY;
        }
        char body[2048], clen_str[16];
        size_t have = (size_t)(hdr_end + 4 <= req + n ? (size_t)(n - (hdr_end + 4 - req)) : 0);
        long clen = copy_header_value(req, hdr_end, "Content-Length", clen_str, sizeof(clen_str)) &&
                            clen_str[strspn(clen_str, "0123456789")] == 0
                        ? strtol(clen_str, NULL, 10) : 0;
        if (clen <= 0 || clen >= (long)sizeof(body) ||
            !read_small_body(fd, hdr_end + 4, have, (size_t)clen, body, sizeof(body))) {
            deny_json(fd, "400 Bad Request", "{\"error\":\"invalid_ticket_request\"}");
            return GATE_DENY;
        }
        // URL-encoded form body: `path=<encoded>`.
        char requested[1024];
        if (!query_param(body, (size_t)clen, "path", requested, sizeof(requested)) || requested[0] != '/') {
            deny_json(fd, "400 Bad Request", "{\"error\":\"invalid_ticket_request\"}");
            return GATE_DENY;
        }
        // The object is verified and pinned NOW: the ticket owns the open
        // descriptor, so a rename, replace, or delete in between cannot
        // change what the anchor download serves, and a vanished file cannot
        // strand it behind a 403.
        int verified_fd = -1;
        if (!rctl_file_policy_open_read(requested, &verified_fd)) {
            deny_json(fd, "403 Forbidden", "{\"error\":\"protected_path\"}");
            return GATE_DENY;
        }
        char ticket[64];
        if (!ticket_issue(verified_fd, requested, ticket, sizeof(ticket))) {
            close(verified_fd);
            deny_json(fd, "503 Service Unavailable", "{\"error\":\"ticket_store_busy\"}");
            return GATE_DENY;
        }
        char out[128];
        snprintf(out, sizeof(out), "{\"ticket\":\"%s\"}", ticket);
        send_text(fd, "200 OK", "application/json", out,
                  "Cache-Control: private, no-store\r\nCross-Origin-Resource-Policy: same-origin\r\n");
        return GATE_HANDLED;
    }

    // Streaming file download: the ticket is validated here but redeemed
    // (consumed) only when the download actually starts, so a failed open or
    // a refused path cannot burn it. The relay hop wins when both credentials
    // are presented — its download never needs a ticket, so none is burned.
    if (!strcmp(path, "/v1/pull_stream")) {
        if (hop_ok) return GATE_OPEN;
        char ticket[128], requested[1024];
        if (query_param(query, query_len, "ticket", ticket, sizeof(ticket)) &&
            query_param(query, query_len, "path", requested, sizeof(requested)) &&
            ticket_validate(ticket, requested)) {
            *ticket_out = true;   // consumed later, after the file opens
            return GATE_OPEN;
        }
        deny_json(fd, "403 Forbidden", "{\"error\":\"lan_token_required\"}");
        return GATE_DENY;
    }

    // WebSocket upgrades live only on the two signaling paths and require the
    // same document origin as the Host authority plus a credential: token
    // header (native) or token subprotocol (browser) or relay hop (tunnel).
    // The decision is returned as GATE_WS and dispatch refuses an upgrade on
    // any other verdict, so a crafted request can never reach 101 around it.
    if (request_is_ws_upgrade(req, hdr_end)) {
        if (strcmp(path, "/ws/term") != 0 && strcmp(path, "/ws/signal") != 0) {
            deny_json(fd, "400 Bad Request", "{\"error\":\"unknown_upgrade\"}");
            return GATE_DENY;
        }
        char origin[256];
        bool origin_present = rctl_http_header_count(req, hdr_end, "Origin") > 0;
        if ((origin_present && !copy_header_value(req, hdr_end, "Origin", origin, sizeof(origin))) ||
            (origin_present && !rctl_http_origin_matches(origin, host_buf))) {
            deny_json(fd, "403 Forbidden", "{\"error\":\"origin_mismatch\"}");
            return GATE_DENY;
        }
        char offered[128] = "";
        if (!ws_subprotocol_token(req, hdr_end, offered, sizeof(offered))) {
            deny_json(fd, "403 Forbidden", "{\"error\":\"lan_token_invalid\"}");
            return GATE_DENY;
        }
        // ws_subprotocol_token leaves the buffer empty when the client offered
        // no subprotocol (native/relay handshakes); only a written value means
        // a validated token subprotocol reached the 101.
        bool offered_valid = offered[0] != 0;
        if (!token_ok && !hop_ok && !offered_valid) {
            deny_json(fd, "403 Forbidden",
                      token_present ? "{\"error\":\"lan_token_invalid\"}"
                                    : "{\"error\":\"lan_token_required\"}");
            return GATE_DENY;
        }
        if (offered_valid) snprintf(ws_proto_out, ws_proto_cap, "%s", offered);
        return GATE_WS;
    }

    // Static page and legacy assets: public, Host-validated only — but never
    // in Relay-only mode and never through the relay hop, which exists for the
    // control tunnel, not for serving the direct-control UI.
    if (is_get && (!strcmp(path, "/") || !strcmp(path, "/index.html") || !strncmp(path, "/vendor/", 8))) {
        if (s->loopback_only || hop_ok) {
            deny_json(fd, "403 Forbidden", "{\"error\":\"relay_only\"}");
            return GATE_DENY;
        }
        return GATE_OPEN;
    }

    // Everything else — the control plane, input, terminal HTTP plane, media,
    // stream, camera control — requires the token or the relay hop.
    if (token_ok || hop_ok) return GATE_OPEN;
    deny_json(fd, "403 Forbidden",
              token_present ? "{\"error\":\"lan_token_invalid\"}"
                            : "{\"error\":\"lan_token_required\"}");
    return GATE_DENY;
}

static void route_request(rctl_http_server *s, int fd, char *req, ssize_t n, char *hdr_end);


// Total buffered POST body bytes across all connection threads: two near-64MB
// uploads would already approach the daemon's jetsam budget.
static long g_body_buffered;
#define RCTL_MAX_BODY_BUFFERED (96 << 20)

static void handle_client(rctl_http_server *s, int fd) {
    // Accumulate the request until the header block terminates (\r\n\r\n):
    // TCP may deliver headers across segments, and the previous single-recv
    // read broke segmented requests and dropped long POST bodies. A monotonic
    // phase deadline bounds how long one connection can hold its thread no
    // matter how slowly the client drips bytes; the receive timeout is
    // cleared after the headers because the terminal and signaling handlers
    // recv() on this fd for their session lifetime.
    static const size_t kMaxHeader = 16 * 1024;
    char *req = (char *)malloc(kMaxHeader + 1);
    if (!req) { close(fd); return; }
    struct timeval tv = { 1, 0 };
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) != 0) {
        // The phase deadline relies on short receive windows; without them a
        // stalled header could block a recv indefinitely.
        free(req);
        close(fd);
        return;
    }
    const double deadline = monotonic_seconds() + 10;
    ssize_t n = 0;
    char *hdr_end = NULL;
    bool complete = false;
    while (n < (ssize_t)kMaxHeader) {
        if (monotonic_seconds() > deadline) break;
        ssize_t k = recv(fd, req + n, kMaxHeader - n, 0);
        if (k < 0 && errno == EINTR) continue;
        if (k < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            // Receive timeout: keep waiting unless the phase deadline passed.
            if (monotonic_seconds() > deadline) break;
            continue;
        }
        if (k <= 0) break;   // EOF or error with a partial request
        n += k;
        req[n] = 0;
        hdr_end = strstr(req, "\r\n\r\n");
        if (hdr_end) { complete = true; break; }
    }
    if (!complete || monotonic_seconds() > deadline) {
        // A stalled or oversized header phase: a partial request gets no
        // response (it never became a request); a full 16 KB block without a
        // terminator answers 431. Either way the thread is freed for the
        // next connection. A request whose final read arrived after the
        // deadline is treated as stalled too.
        if (!complete && n >= (ssize_t)kMaxHeader)
            send_text(fd, "431 Request Header Fields Too Large", "text/plain", "headers too large");
        free(req);
        close(fd);
        return;
    }
    // Terminate the header block inside the buffer so strstr-based parameter
    // parsing cannot cross into the body or a pipelined follow-up request;
    // hdr_end + 4 still points at the first body byte.
    hdr_end[2] = 0;
    hdr_end[3] = 0;
    // The timeout bounds only the header phase: the terminal and signaling
    // handlers recv() on this fd for the lifetime of the session and must
    // not inherit a per-second ceiling. A failed reset would strand the
    // session with it, so the upgrade is refused instead.
    memset(&tv, 0, sizeof(tv));
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) != 0) {
        free(req);
        close(fd);
        return;
    }
    route_request(s, fd, req, n, hdr_end);
    free(req);
}

static void route_request(rctl_http_server *s, int fd, char *req, ssize_t n, char *hdr_end) {
    // The gate decides before any dispatch: request-line syntax, Host binding,
    // probe/camera/bootstrap/ticket exceptions, and the token policy.
    bool probe = false;
    char ws_proto[128];
    bool ticket_download = false;
    int gate = request_gate(s, fd, req, n, hdr_end, &probe, &ticket_download, ws_proto, sizeof(ws_proto));
    if (gate == GATE_HANDLED || gate == GATE_DENY) {
        close(fd);
        return;
    }
    if (strncmp(req, "GET /v1/pull_stream?", 20) == 0) {
        // A hop-authenticated relay download needs no ticket; a ticketed LAN
        // download redeems after the file opens successfully.
        stream_file_download(fd, req, ticket_download);
        close(fd);
    } else if (strncmp(req, "GET /ws/term", 12) == 0) {
        // Only the gate's own upgrade decision may reach 101: a crafted
        // request with a key but no upgrade cannot bypass the WS policy.
        if (gate != GATE_WS) {
            send_text(fd, "400 Bad Request", "text/plain", "not a websocket upgrade");
            close(fd);
            return;
        }
        rctl_term_handle_ws(fd, req, ws_proto);
    } else if (strncmp(req, "GET /ws/signal", 14) == 0) {
        if (gate != GATE_WS) {
            send_text(fd, "400 Bad Request", "text/plain", "not a websocket upgrade");
            close(fd);
            return;
        }
        rctl_signal_handle_ws(fd, req, ws_proto);
    } else if (strncmp(req, "GET /stream", 11) == 0) {
        const char *h =
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
            "Transfer-Encoding: chunked\r\nCache-Control: no-cache\r\n"
            "Connection: close\r\n\r\n";
        if (!send_full(fd, h, strlen(h))) { close(fd); return; }
        struct timeval tv = { 1, 0 }; // drop a stalled (e.g. dropped-Wi-Fi) client fast
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        sub_set_nonblock(fd);
        pthread_mutex_lock(&s->mtx);
        int slot = -1;
        for (int i = 0; i < RCTL_MAX_CLIENTS; i++) if (s->subs[i].fd < 0) { slot = i; break; }
        bool became_active = false;
        rctl_session_cb scb = s->session_cb; void *sctx = s->session_ctx;
        if (slot >= 0) {
            rctl_sub *sub = &s->subs[slot];
            sub->fd = fd; sub->head = sub->count = 0; sub->cur_off = 0;
            sub->needs_keyframe = false; sub->lagging = false;
            // Prime the subscriber: cached keyframe (so it can decode immediately)
            // then the current orientation.
            if (s->keyframe) {
                size_t kt = 0;
                uint8_t *kb = build_video_chunk(1, s->keyframe_pts_us, s->keyframe, s->keyframe_len, &kt);
                sub_enqueue(sub, kb, kt, true, true);
            }
            { uint8_t ob = (uint8_t)s->orientation; size_t ot = 0;
              uint8_t *obf = build_frame_chunk(2, &ob, 1, &ot); sub_enqueue(sub, obf, ot, false, false); }
            if (!sub_flush(sub)) sub_close(sub);
            else if (!s->was_active) { s->was_active = true; became_active = true; }  // 0 -> 1: wake
        } else close(fd);
        pthread_mutex_unlock(&s->mtx);
        if (became_active && scb) scb(sctx, true);
        // keep fd open for streaming (pushed from rctl_http_push_au)
    } else if (strncmp(req, "GET /input", 10) == 0) {
        int phase = 0, id = 0; double x = 0, y = 0;
        char *p;
        if ((p = strstr(req, "phase="))) phase = atoi(p + 6);
        if ((p = strstr(req, "id=")))    id    = atoi(p + 3);
        if ((p = strstr(req, "x=")))     x     = atof(p + 2);
        if ((p = strstr(req, "y=")))     y     = atof(p + 2);
        pthread_mutex_lock(&s->mtx);
        rctl_input_cb cb = s->input_cb; void *cx = s->input_ctx;
        pthread_mutex_unlock(&s->mtx);
        if (cb) cb(cx, phase, id, x, y);
        send_text(fd, "200 OK", "text/plain", "ok");
        close(fd);
    } else if (strncmp(req, "GET /key", 8) == 0) {
        int page = 0x07, usage = 0, down = 0;
        char *p;
        if ((p = strstr(req, "p="))) page  = atoi(p + 2);
        if ((p = strstr(req, "u="))) usage = atoi(p + 2);
        if ((p = strstr(req, "d="))) down  = atoi(p + 2);
        pthread_mutex_lock(&s->mtx);
        rctl_key_cb cb = s->key_cb; void *cx = s->key_ctx;
        pthread_mutex_unlock(&s->mtx);
        if (cb) cb(cx, page, usage, down);
        send_text(fd, "200 OK", "text/plain", "ok");
        close(fd);
    } else if (strncmp(req, "GET /config", 11) == 0) {
        int fps = 30, br = 20000000; double sc = 1.0;
        char *p;
        if ((p = strstr(req, "fps=")))     fps = atoi(p + 4);
        if ((p = strstr(req, "scale=")))   sc  = atof(p + 6);
        if ((p = strstr(req, "bitrate="))) br  = atoi(p + 8);
        pthread_mutex_lock(&s->mtx);
        rctl_reconfigure_cb cb = s->recfg; void *cx = s->recfg_ctx;
        pthread_mutex_unlock(&s->mtx);
        fprintf(stderr, "[http] /config fps=%d scale=%.2f bitrate=%d\n", fps, sc, br);
        if (cb) cb(cx, fps, sc, br);
        send_text(fd, "200 OK", "text/plain", "ok");
        close(fd);
    } else if (strncmp(req, "GET /audio_test", 15) == 0) {
        bool on = strstr(req, "on=1") != NULL;
        int hz = 440;
        char *p;
        if ((p = strstr(req, "hz="))) hz = atoi(p + 3);
        if (hz < 80) hz = 80;
        if (hz > 2000) hz = 2000;
        pthread_mutex_lock(&s->mtx);
        s->audio_test_on = on;
        s->audio_test_hz = hz;
        if (on) {
            s->audio_test_pts_us = 0;
            s->audio_test_phase = 0;
        }
        pthread_mutex_unlock(&s->mtx);
        send_text(fd, "200 OK", "text/plain", on ? "on" : "off");
        close(fd);
    } else if (strncmp(req, "GET /orient", 11) == 0) {
        char body[16];
        snprintf(body, sizeof(body), "%d", s->orientation);
        send_text(fd, "200 OK", "text/plain", body);
        close(fd);
    } else if (strncmp(req, "GET /v1/", 8) == 0 || strncmp(req, "POST /v1/", 9) == 0) {
        // REST automation plane: route "/v1/..." to the registered handler, which
        // does the action and returns a JSON body. Parse path + query without
        // clobbering the buffer (we still need it to find the POST body).
        bool isPost = (req[0] == 'P');
        const char *method = isPost ? "POST" : "GET";
        const char *target = req + (isPost ? 5 : 4);   // skip "POST " / "GET "
        char tbuf[1024]; size_t ti = 0;
        while (target[ti] && target[ti] != ' ' && ti < sizeof(tbuf) - 1) { tbuf[ti] = target[ti]; ti++; }
        if (target[ti] && target[ti] != ' ') {
            // A target longer than the parse buffer would dispatch a silently
            // truncated path: refuse rather than operate on a different file.
            send_text(fd, "400 Bad Request", "application/json", "{\"error\":\"target too long\"}");
            close(fd);
            return;
        }
        tbuf[ti] = 0;
        char *path = tbuf, *query = strchr(tbuf, '?');
        if (query) { *query = 0; query++; } else query = (char *)"";

        // Read the POST body (best-effort up to Content-Length beyond the first recv).
        // Cap at 64 MB — large enough for file uploads, bounded against abuse.
        char *bodybuf = NULL; const char *body = ""; int body_len = 0;
        long body_charge = 0;  // buffered-body bytes charged against g_body_buffered
        char content_type[96] = {0};
        const char *ct = rctl_http_header(req, hdr_end, "Content-Type");
        if (ct) {
            size_t ci = 0;
            while (ct[ci] && ct[ci] != '\r' && ct[ci] != ';' && ci < sizeof(content_type) - 1) {
                content_type[ci] = ct[ci];
                ci++;
            }
            content_type[ci] = 0;
        }
        if (isPost && hdr_end) {
            // Reject obsolete/malformed field syntax before trusting any
            // framing field: whitespace before the colon or a line without a
            // colon makes the request invalid (RFC 9112 §5.1) and could
            // otherwise smuggle an unrecognized Content-Length past the
            // checks below, reaching /v1/push as an empty body. The scan
            // shares the CRLF line boundaries of the field lookup, so it can
            // never accept a field the lookup would miss; the last field
            // line is terminated by the block terminator's own first CRLF.
            if (!rctl_http_fields_valid(req, hdr_end)) {
                send_text(fd, "400 Bad Request", "text/plain", "malformed header field");
                close(fd);
                return;
            }
            const char *cl = rctl_http_header(req, hdr_end, "Content-Length");
            const int cl_count = rctl_http_header_count(req, hdr_end, "Content-Length");
            // Chunked bodies are not supported: without Content-Length they
            // would reach /v1/push as an empty body and truncate the target
            // file with a success response (RFC 9112 §6.3).
            if (rctl_http_header_count(req, hdr_end, "Transfer-Encoding") > 0) {
                send_text(fd, "400 Bad Request", "text/plain", "transfer-encoding unsupported");
                close(fd);
                return;
            }
            // A POST without Content-Length carries no body. A duplicated
            // field, a malformed value, or a length beyond the 64 MB cap must
            // be rejected before the REST layer: /v1/push opens its target
            // with "wb" and would report success after truncating the file
            // with an empty or truncated body.
            if (cl_count > 1) {
                send_text(fd, "400 Bad Request", "text/plain", "duplicate content-length");
                close(fd);
                return;
            }
            long clen_l = 0;
            if (cl_count == 1) {
                // Strict parse: digits only (strtol would accept "+0" and
                // numeric prefixes), and the value must end at the header
                // line's CRLF, not any stray CR.
                char *endp = NULL;
                errno = 0;
                if (!cl || cl[0] < '0' || cl[0] > '9') {
                    send_text(fd, "400 Bad Request", "text/plain", "invalid content-length");
                    close(fd);
                    return;
                }
                clen_l = strtol(cl, &endp, 10);
                if (errno == ERANGE || endp == cl || clen_l < 0) {
                    send_text(fd, "400 Bad Request", "text/plain", "invalid content-length");
                    close(fd);
                    return;
                }
                while (*endp == ' ' || *endp == '\t') endp++;
                if (endp[0] != '\r' || endp[1] != '\n') {
                    send_text(fd, "400 Bad Request", "text/plain", "invalid content-length");
                    close(fd);
                    return;
                }
                if (clen_l >= (64 << 20)) {
                    send_text(fd, "413 Payload Too Large", "text/plain", "body too large");
                    close(fd);
                    return;
                }
            }
            int clen = (int)clen_l;
            if (clen > 0) {
                long buffered = __atomic_add_fetch(&g_body_buffered, clen, __ATOMIC_RELAXED);
                if (buffered > RCTL_MAX_BODY_BUFFERED) {
                    __atomic_sub_fetch(&g_body_buffered, clen, __ATOMIC_RELAXED);
                    send_text(fd, "503 Service Unavailable", "text/plain", "upload budget busy");
                    close(fd);
                    return;
                }
                char *bstart = hdr_end + 4;
                int have = (int)(n - (bstart - req)), got = have > clen ? clen : have;
                bodybuf = (char *)malloc(clen + 1);
                if (!bodybuf) {
                    __atomic_sub_fetch(&g_body_buffered, clen, __ATOMIC_RELAXED);
                    send_text(fd, "500 Internal Server Error", "text/plain", "out of memory");
                    close(fd);
                    return;
                }
                if (have > 0) memcpy(bodybuf, bstart, got);
                // Bound the upload read like the header phase: a stalled
                // upload cannot hold its connection thread forever. A short
                // receive timeout alone would abort a healthy but paused
                // upload, so a timeout only ends the read once the phase
                // deadline passed.
                struct timeval btv = { 1, 0 };
                if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &btv, sizeof(btv)) != 0) {
                    // Without bounded receives the held upload budget could
                    // block a recv indefinitely; fail this request closed.
                    __atomic_sub_fetch(&g_body_buffered, clen, __ATOMIC_RELAXED);
                    free(bodybuf);
                    send_text(fd, "500 Internal Server Error", "text/plain", "unbounded receive");
                    close(fd);
                    return;
                }
                const double body_deadline = monotonic_seconds() + 60;
                while (got < clen) {
                    if (monotonic_seconds() > body_deadline) break;
                    ssize_t k = recv(fd, bodybuf + got, clen - got, 0);
                    if (k < 0 && errno == EINTR) continue;
                    if (k < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                        if (monotonic_seconds() > body_deadline) break;
                        continue;
                    }
                    if (k <= 0) break;
                    got += (int)k;
                }
                memset(&btv, 0, sizeof(btv));
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &btv, sizeof(btv));
                if (got < clen || monotonic_seconds() > body_deadline) {
                    // A stalled, truncated, or over-deadline upload must not
                    // reach the REST layer: /v1/push would happily write a
                    // partial file and report success. Release the buffer and
                    // its budget charge together before answering.
                    free(bodybuf);
                    __atomic_sub_fetch(&g_body_buffered, clen, __ATOMIC_RELAXED);
                    send_text(fd, "400 Bad Request", "text/plain", "incomplete body");
                    close(fd);
                    return;
                }
                bodybuf[got] = 0; body = bodybuf; body_len = got;
                // The charge stays held while the REST handler owns the
                // buffer and is released right after the handler returns,
                // before the response is written — a concurrent upload can
                // only claim the budget for memory that is actually live.
                body_charge = clen;
            }
        }

        pthread_mutex_lock(&s->mtx);
        rctl_rest_cb cb = s->rest_cb; void *cx = s->rest_ctx;
        pthread_mutex_unlock(&s->mtx);
        int status = 200, out_len = 0; const char *out_ctype = NULL;
        char *resp = cb ? cb(cx, method, content_type, path, query, body, body_len, probe,
                             &status, &out_len, &out_ctype) : NULL;
        // The request body and its budget charge end with the handler; the
        // response stays live until it has been written. A stalled client
        // must not hold its connection slot forever, so the reply write runs
        // under a send timeout (cleared afterwards; WS handlers rely on
        // unbounded sends on the same fd only in their own sessions).
        free(bodybuf);
        if (body_charge) __atomic_sub_fetch(&g_body_buffered, body_charge, __ATOMIC_RELAXED);
        struct timeval stv = { 10, 0 };
        if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &stv, sizeof(stv)) != 0) {
            // An unbounded reply write could hold the connection slot (and a
            // possibly large response buffer) forever; refuse this request.
            free(resp);
            close(fd);
            return;
        }
        const char *line = status == 202 ? "202 Accepted" :
                           status == 400 ? "400 Bad Request" :
                           status == 403 ? "403 Forbidden" :
                           status == 404 ? "404 Not Found" :
                           status == 405 ? "405 Method Not Allowed" :
                           status == 409 ? "409 Conflict" :
                           status == 415 ? "415 Unsupported Media Type" :
                           status == 502 ? "502 Bad Gateway" :
                           status == 503 ? "503 Service Unavailable" :
                           status == 504 ? "504 Gateway Timeout" :
                           status == 500 ? "500 Internal Server Error" : "200 OK";
        if (out_ctype)   // explicit content-type => send exactly out_len raw bytes (may be 0)
            send_data(fd, line, out_ctype, resp ? resp : "", out_len);
        else             // default: treat resp as a NUL-terminated JSON string
            send_data(fd, line, "application/json", resp ? resp : "{}", resp ? strlen(resp) : 2);
        free(resp);
        memset(&stv, 0, sizeof(stv));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &stv, sizeof(stv));
        close(fd);
    } else if (strncmp(req, "GET /vendor/", 12) == 0) {
        const char *target = req + 4;
        char rel[256]; size_t ri = 0;
        while (target[ri] && target[ri] != ' ' && ri < sizeof(rel) - 1) { rel[ri] = target[ri]; ri++; }
        rel[ri] = 0;
        if (strstr(rel, "..") || strchr(rel, 92)) {
            send_text(fd, "400 Bad Request", "text/plain", "bad path");
        } else {
            // Resolve the asset relative to the pinned web-client directory:
            // O_NOFOLLOW_ANY refuses symlinks on every component, so a
            // planted link cannot serve a protected file.
            char dir[PATH_MAX];
            snprintf(dir, sizeof(dir), "%s", RCTL_WEB_CLIENT);
            char *asset_dir_slash = strrchr(dir, '/');
            if (!asset_dir_slash) { send_text(fd, "404 Not Found", "text/plain", "not found"); close(fd); return; }
            *asset_dir_slash = 0;
            int dirfd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            int asset_fd = dirfd >= 0
                ? openat(dirfd, rel[0] == '/' ? rel + 1 : rel, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
                : -1;
            if (dirfd >= 0) close(dirfd);
            struct stat st;
            if (asset_fd >= 0 && fstat(asset_fd, &st) == 0 && S_ISREG(st.st_mode)) {
                size_t len = (size_t)st.st_size;
                char *body = (char *)malloc(len + 1);
                if (body && read(asset_fd, body, len) == (ssize_t)len) {
                    char name[288];
                    snprintf(name, sizeof(name), "/vendor/%s", rel);
                    send_data(fd, "200 OK", ctype_for_path(name), body, len);
                } else {
                    send_text(fd, "404 Not Found", "text/plain", "not found");
                }
                free(body);
            } else {
                send_text(fd, "404 Not Found", "text/plain", "not found");
            }
            if (asset_fd >= 0) close(asset_fd);
        }
        close(fd);
    } else if (strncmp(req, "GET / ", 6) == 0 || strncmp(req, "GET /index", 10) == 0) {
        size_t hlen = 0;
        char *html = read_file(RCTL_WEB_CLIENT, &hlen);
        // send_data with the real length, not strlen: the inlined web bundle can
        // contain NUL bytes (embedded WASM) that would truncate a strlen() send.
        if (html) {
            send_data(fd, "200 OK", "text/html; charset=utf-8", html, hlen);
        } else {
            log_control_client_unavailable(s);
            send_text(fd, "503 Service Unavailable", "text/plain; charset=utf-8",
                      "Control client unavailable\n");
        }
        free(html);
        close(fd);
    } else {
        send_text(fd, "404 Not Found", "text/plain", "not found");
        close(fd);
    }
}

// One connection per thread so a slow request (e.g. /v1/camera waiting for the
// in-app capturer to POST its photo back) can't block other requests.
struct rctl_conn { rctl_http_server *s; int fd; bool loopback; };
static void release_conn_slot(rctl_http_server *s, bool loopback) {
    // The peer-kind counter is released first: the total decrement is the
    // worker's final access to the server, so a stop() that observes zero
    // can free it without a worker touching freed memory afterwards. The
    // release ordering pairs with the acquire load in stop().
    if (loopback) __atomic_sub_fetch(&s->live_loopback, 1, __ATOMIC_RELAXED);
    else __atomic_sub_fetch(&s->live_remote, 1, __ATOMIC_RELAXED);
    __atomic_sub_fetch(&s->live_conns, 1, __ATOMIC_RELEASE);
}
static void *conn_thread(void *arg) {
    struct rctl_conn *c = (struct rctl_conn *)arg;
    rctl_http_server *s = c->s;
    const bool loopback = c->loopback;
    @autoreleasepool {
        handle_client(s, c->fd);
    }
    free(c);
    release_conn_slot(s, loopback);
    return NULL;
}
static void *accept_loop(void *arg) {
    rctl_http_server *s = (rctl_http_server *)arg;
    while (s->running) {
        struct sockaddr_in ca; socklen_t cl = sizeof(ca);
        int fd = accept(s->listen_fd, (struct sockaddr *)&ca, &cl);
        if (fd < 0) { if (!s->running) break; continue; }
        int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        // Bound concurrent connection threads: each holds a ~0.5-1 MB stack
        // under the daemon's jetsam ceiling, so an unbounded connection flood
        // could OOM rctld and disconnect every real client. Refuse the excess
        // instead of falling over. Loopback connections (the relay's local
        // tunnel and the daemon's own round-trips) get a higher total cap so
        // long-lived LAN terminal and signaling sessions cannot starve them,
        // but never an unbounded one.
        const bool loopback = ca.sin_addr.s_addr == htonl(INADDR_LOOPBACK);
        const int live = __atomic_add_fetch(&s->live_conns, 1, __ATOMIC_RELAXED);
        const int peer = loopback
            ? __atomic_add_fetch(&s->live_loopback, 1, __ATOMIC_RELAXED)
            : __atomic_add_fetch(&s->live_remote, 1, __ATOMIC_RELAXED);
        // LAN mode reserves the remote cap for LAN peers: loopback may grow
        // only into the unreserved remainder, so local sessions can never
        // shut LAN peers out. In Relay-only mode loopback owns the whole
        // budget. Each cap reads its own counter, so a slot freed by one
        // peer kind is never miscounted against the other.
        const int peer_cap = s->loopback_only ? RCTL_MAX_CONNS_TOTAL
                                              : RCTL_MAX_CONNS_TOTAL - RCTL_MAX_CONNS;
        if (live > RCTL_MAX_CONNS_TOTAL || peer > (loopback ? peer_cap : RCTL_MAX_CONNS)) {
            release_conn_slot(s, loopback);
            send_text(fd, "503 Service Unavailable", "text/plain", "too many connections");
            close(fd);
            continue;
        }
        struct rctl_conn *c = (struct rctl_conn *)malloc(sizeof *c);
        if (!c) {
            release_conn_slot(s, loopback);
            close(fd);
            continue;
        }
        c->s = s; c->fd = fd; c->loopback = loopback;
        pthread_t t;
        if (pthread_create(&t, NULL, conn_thread, c) == 0) pthread_detach(t);
        else {
            // Handling inline could occupy the single accept loop for the
            // lifetime of a WebSocket session; refuse the connection instead.
            send_text(fd, "503 Service Unavailable", "text/plain", "thread unavailable");
            free(c);
            release_conn_slot(s, loopback);
            close(fd);
        }
    }
    return NULL;
}

rctl_http_server *rctl_http_start(int port, bool loopback_only) {
    ticket_store_init();
    signal(SIGPIPE, SIG_IGN);
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) { fprintf(stderr, "[http] socket failed\n"); return NULL; }
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(loopback_only ? INADDR_LOOPBACK : INADDR_ANY);
    addr.sin_port = htons((uint16_t)port);
    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[http] bind %d failed: %s\n", port, strerror(errno));
        close(lfd); return NULL;
    }
    if (listen(lfd, 8) < 0) { fprintf(stderr, "[http] listen failed\n"); close(lfd); return NULL; }

    rctl_http_server *s = (rctl_http_server *)calloc(1, sizeof(rctl_http_server));
    s->listen_fd = lfd; s->port = port; s->running = true; s->orientation = 1;
    s->loopback_only = loopback_only;
    s->audio_test_hz = 440;
    for (int i = 0; i < RCTL_MAX_CLIENTS; i++) s->subs[i].fd = -1;
    pthread_mutex_init(&s->mtx, NULL);
    s->audio_thread_started = pthread_create(&s->audio_thread, NULL, audio_test_loop, s) == 0;
    pthread_create(&s->thread, NULL, accept_loop, s);
    fprintf(stderr, "[http] serving on %s:%d\n", loopback_only ? "127.0.0.1" : "0.0.0.0", port);
    return s;
}

// Enqueue a framed message to every subscriber (own copy each) and flush what
// the sockets accept without blocking; reap subscribers whose socket errored.
static void broadcast_frame_locked(rctl_http_server *s, const uint8_t *buf, size_t len,
                                   bool is_video, bool is_key) {
    for (int i = 0; i < RCTL_MAX_CLIENTS; i++) {
        rctl_sub *sub = &s->subs[i];
        if (sub->fd < 0) continue;
        uint8_t *copy = (uint8_t *)malloc(len);
        if (copy) { memcpy(copy, buf, len); sub_enqueue(sub, copy, len, is_video, is_key); }
        if (!sub_flush(sub)) sub_close(sub);
    }
}

// Broadcast a typed control frame to all subscribers (caller holds the mutex).
static void broadcast_locked(rctl_http_server *s, uint8_t type, const uint8_t *data, size_t len) {
    size_t total = 0;
    uint8_t *buf = build_frame_chunk(type, data, len, &total);
    if (!buf) return;
    broadcast_frame_locked(s, buf, total, false, false);
    free(buf);
}

static void broadcast_video_locked(rctl_http_server *s, uint8_t type, uint64_t pts_us,
                                   const uint8_t *data, size_t len) {
    size_t total = 0;
    uint8_t *buf = build_video_chunk(type, pts_us, data, len, &total);
    if (!buf) return;
    broadcast_frame_locked(s, buf, total, true, type == 1);
    free(buf);
}

void rctl_http_push_au(rctl_http_server *s, const uint8_t *data, size_t len,
                       bool keyframe, uint64_t pts_us) {
    if (!s) return;
    pthread_mutex_lock(&s->mtx);
    if (keyframe) {
        uint8_t *k = (uint8_t *)malloc(len);
        if (k) {
            memcpy(k, data, len);
            free(s->keyframe);
            s->keyframe = k;
            s->keyframe_len = len;
            s->keyframe_pts_us = pts_us;
        }
    }
    broadcast_video_locked(s, keyframe ? 1 : 0, pts_us, data, len);   // may prune dead subscribers
    bool became_idle = false;
    rctl_session_cb scb = s->session_cb; void *sctx = s->session_ctx;
    if (s->was_active && count_clients_locked(s) == 0) { s->was_active = false; became_idle = true; }  // 1 -> 0: sleep
    pthread_mutex_unlock(&s->mtx);
    if (became_idle && scb) scb(sctx, false);
}

void rctl_http_push_pcm_s16le(rctl_http_server *s, const int16_t *samples,
                              uint16_t frames, uint8_t channels,
                              uint32_t sample_rate, uint64_t pts_us) {
    if (!s || !samples || frames == 0 || channels == 0 ||
        channels > RCTL_AUDIO_MAX_CHANNELS || frames > RCTL_AUDIO_MAX_FRAMES ||
        sample_rate == 0) return;

    size_t sample_count = (size_t)frames * (size_t)channels;
    size_t pcm_len = sample_count * 2;
    size_t payload_len = 16 + pcm_len;
    uint8_t payload[16 + RCTL_AUDIO_MAX_FRAMES * RCTL_AUDIO_MAX_CHANNELS * 2];
    put_be64(payload, pts_us);
    put_be32(payload + 8, sample_rate);
    payload[12] = channels;
    payload[13] = 2;
    payload[14] = (frames >> 8) & 0xff;
    payload[15] = frames & 0xff;
    for (size_t i = 0; i < sample_count; i++) put_le16(payload + 16 + i * 2, samples[i]);

    pthread_mutex_lock(&s->mtx);
    broadcast_locked(s, 4, payload, payload_len);
    bool became_idle = false;
    rctl_session_cb scb = s->session_cb; void *sctx = s->session_ctx;
    if (s->was_active && count_clients_locked(s) == 0) {
        s->was_active = false;
        became_idle = true;
    }
    pthread_mutex_unlock(&s->mtx);
    if (became_idle && scb) scb(sctx, false);
}

void rctl_http_set_orientation(rctl_http_server *s, int orientation) {
    if (!s) return;
    pthread_mutex_lock(&s->mtx);
    if (orientation != s->orientation) {
        s->orientation = orientation;
        uint8_t b = (uint8_t)orientation;
        broadcast_locked(s, 2, &b, 1);
    }
    pthread_mutex_unlock(&s->mtx);
}

void rctl_http_signal_reset(rctl_http_server *s) {
    if (!s) return;
    pthread_mutex_lock(&s->mtx);
    free(s->keyframe); s->keyframe = NULL; s->keyframe_len = 0;
    broadcast_locked(s, 3, NULL, 0);
    pthread_mutex_unlock(&s->mtx);
}

void rctl_http_set_reconfigure(rctl_http_server *s, rctl_reconfigure_cb cb, void *ctx) {
    if (!s) return;
    pthread_mutex_lock(&s->mtx);
    s->recfg = cb; s->recfg_ctx = ctx;
    pthread_mutex_unlock(&s->mtx);
}

void rctl_http_set_input(rctl_http_server *s, rctl_input_cb cb, void *ctx) {
    if (!s) return;
    pthread_mutex_lock(&s->mtx);
    s->input_cb = cb; s->input_ctx = ctx;
    pthread_mutex_unlock(&s->mtx);
}

void rctl_http_set_key(rctl_http_server *s, rctl_key_cb cb, void *ctx) {
    if (!s) return;
    pthread_mutex_lock(&s->mtx);
    s->key_cb = cb; s->key_ctx = ctx;
    pthread_mutex_unlock(&s->mtx);
}

void rctl_http_set_rest(rctl_http_server *s, rctl_rest_cb cb, void *ctx) {
    if (!s) return;
    pthread_mutex_lock(&s->mtx);
    s->rest_cb = cb; s->rest_ctx = ctx;
    pthread_mutex_unlock(&s->mtx);
}

void rctl_http_set_session(rctl_http_server *s, rctl_session_cb cb, void *ctx) {
    if (!s) return;
    pthread_mutex_lock(&s->mtx);
    s->session_cb = cb; s->session_ctx = ctx;
    pthread_mutex_unlock(&s->mtx);
}

bool rctl_http_has_clients(rctl_http_server *s) {
    if (!s) return false;
    pthread_mutex_lock(&s->mtx);
    bool any = count_clients_locked(s) > 0;
    pthread_mutex_unlock(&s->mtx);
    return any;
}

void rctl_http_egress_sample(rctl_http_server *s, int *out_max_queue, int *out_lagged) {
    int maxq = 0, lagged = 0;
    if (s) {
        pthread_mutex_lock(&s->mtx);
        for (int i = 0; i < RCTL_MAX_CLIENTS; i++) {
            rctl_sub *sub = &s->subs[i];
            if (sub->fd < 0) continue;
            if (sub->count > maxq) maxq = sub->count;
            if (sub->lagging) { lagged++; sub->lagging = false; }
        }
        pthread_mutex_unlock(&s->mtx);
    }
    if (out_max_queue) *out_max_queue = maxq;
    if (out_lagged) *out_lagged = lagged;
}

void rctl_http_stop(rctl_http_server *s) {
    if (!s) return;
    ticket_store_shutdown();   // close any ticket-owned object descriptors
    s->running = false;
    close(s->listen_fd);
    if (s->audio_thread_started) pthread_join(s->audio_thread, NULL);
    // Join the accept loop first: a thread that just returned from accept()
    // increments the counters below, so draining before it exits would free
    // the server under it.
    pthread_join(s->thread, NULL);
    // Detached connection threads touch the server (live_conns, keyframe,
    // subscriber slots) until their handler returns; wait for them to drain
    // before freeing anything. If a handler does not drain in time, leave the
    // struct allocated rather than hand freed memory to a live thread.
    const double give_up = monotonic_seconds() + 10;
    // Acquire pairs with the workers' release decrement: once zero is
    // observed, no worker will touch the server again.
    while (__atomic_load_n(&s->live_conns, __ATOMIC_ACQUIRE) > 0) {
        if (monotonic_seconds() > give_up) return;  // leak instead of a use-after-free
        usleep(20000);
    }
    pthread_mutex_lock(&s->mtx);
    for (int i = 0; i < RCTL_MAX_CLIENTS; i++) if (s->subs[i].fd >= 0) sub_close(&s->subs[i]);
    free(s->keyframe);
    pthread_mutex_unlock(&s->mtx);
    free(s);
}
