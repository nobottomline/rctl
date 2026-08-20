// HttpStreamServer.mm — minimal HTTP server that streams H.264 access units to
// browsers, where WebCodecs decodes them. Application framing inside the HTTP
// (chunked) body:
//   [1 byte type][4 byte BE length][type-specific payload].
// Type 0/1 video payload: [8 byte BE pts_us][Annex-B data].
// Type 4 PCM payload: [8 byte BE pts_us][4 byte BE rate][channels][bytes/sample]
//                     [2 byte BE frames][interleaved s16le data].

#import "net/HttpStreamServer.h"
#import "net/Term.h"
#import <pthread.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>
#import <math.h>
#import <sys/stat.h>
#import <time.h>

#define RCTL_MAX_CLIENTS 8
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
};

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
                      const void *body, size_t len);
static void send_text(int fd, const char *status, const char *ctype, const char *body);
static bool send_full(int fd, const void *buf, size_t len);

static bool decode_query_value(const char *source, size_t source_len, char *out, size_t out_cap) {
    if (!out_cap) return false;
    size_t oi = 0;
    for (size_t i = 0; i < source_len; i++) {
        unsigned char value = (unsigned char)source[i];
        if (value == '%') {
            if (i + 2 >= source_len) return false;
            char hex[3] = { source[i + 1], source[i + 2], 0 };
            char *end = NULL;
            long decoded = strtol(hex, &end, 16);
            if (!end || *end || decoded <= 0 || decoded > 255) return false;
            value = (unsigned char)decoded;
            i += 2;
        }
        if (oi + 1 >= out_cap) return false;
        out[oi++] = (char)value;
    }
    out[oi] = 0;
    return oi > 0;
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
            return decode_query_value(query + sizeof(key) - 1,
                                      (size_t)(pair_end - query - (sizeof(key) - 1)),
                                      out, out_cap);
        }
        query = pair_end + (pair_end < target_end ? 1 : 0);
    }
    return false;
}

static void download_name(const char *path, char *out, size_t out_cap) {
    const char *base = strrchr(path, '/');
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

static void stream_file_download(int fd, const char *request) {
    char path[1024];
    if (!pull_stream_path(request, path, sizeof(path))) {
        send_text(fd, "400 Bad Request", "application/json", "{\"error\":\"invalid path\"}");
        return;
    }

    int file_fd = open(path, O_RDONLY | O_CLOEXEC);
    if (file_fd < 0) {
        send_text(fd, errno == ENOENT ? "404 Not Found" : "403 Forbidden",
                  "application/json", "{\"error\":\"cannot open\"}");
        return;
    }
    struct stat st;
    if (fstat(file_fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0) {
        close(file_fd);
        send_text(fd, "400 Bad Request", "application/json", "{\"error\":\"not a regular file\"}");
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
                      const void *body, size_t len) {
    // Ship the same security headers the relay sets on the control page, so the
    // device-served (LAN) page isn't a weaker origin: a strict CSP (frame-ancestors
    // none, no eval, https-only images), nosniff, and no referrer leakage. The CSP
    // is ignored on non-document responses (the /v1 JSON) but nosniff still helps.
    char hdr[640];
    int n = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
        "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        "Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; "
        "style-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss: stun: turn: turns:; "
        "img-src 'self' data: blob: https:; media-src 'self' blob:; frame-ancestors 'none'; "
        "base-uri 'none'; form-action 'self'\r\n"
        "Connection: close\r\n\r\n",
        status, ctype, len);
    if (n < 0 || n >= (int)sizeof(hdr)) return;   // header overflow: drop, don't send garbage
    send_full(fd, hdr, n);
    send_full(fd, body, len);
}
static void send_text(int fd, const char *status, const char *ctype, const char *body) {
    send_data(fd, status, ctype, body, strlen(body));
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
                        "/var/mobile/rctl/index.html is missing, empty, or unreadable\n");
    }
}

static void handle_client(rctl_http_server *s, int fd) {
    char req[2048];
    ssize_t n = recv(fd, req, sizeof(req) - 1, 0);
    if (n <= 0) { close(fd); return; }
    req[n] = 0;

    if (strncmp(req, "GET /v1/pull_stream?", 20) == 0) {
        stream_file_download(fd, req);
        close(fd);
    } else if (strncmp(req, "GET /ws/term", 12) == 0) {
        rctl_term_handle_ws(fd, req);
    } else if (strncmp(req, "GET /ws/signal", 14) == 0) {
        rctl_signal_handle_ws(fd, req);
    } else if (strncmp(req, "GET /stream", 11) == 0) {
        const char *h =
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
            "Transfer-Encoding: chunked\r\nCache-Control: no-cache\r\n"
            "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n";
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
        tbuf[ti] = 0;
        char *path = tbuf, *query = strchr(tbuf, '?');
        if (query) { *query = 0; query++; } else query = (char *)"";

        // Read the POST body (best-effort up to Content-Length beyond the first recv).
        // Cap at 64 MB — large enough for file uploads, bounded against abuse.
        char *bodybuf = NULL; const char *body = ""; int body_len = 0;
        char *hdr_end = strstr(req, "\r\n\r\n");
        char content_type[96] = {0};
        char *ct = strstr(req, "\r\nContent-Type:");
        if (ct && (!hdr_end || ct < hdr_end)) {
            ct += 15;
            while (*ct == ' ' || *ct == '\t') ct++;
            size_t ci = 0;
            while (ct[ci] && ct[ci] != '\r' && ct[ci] != ';' && ci < sizeof(content_type) - 1) {
                content_type[ci] = ct[ci];
                ci++;
            }
            content_type[ci] = 0;
        }
        if (isPost && hdr_end) {
            char *cl = strstr(req, "Content-Length:");
            int clen = cl ? atoi(cl + 15) : 0;
            if (clen > 0 && clen < (64 << 20)) {
                char *bstart = hdr_end + 4;
                int have = (int)(n - (bstart - req)), got = have > clen ? clen : have;
                bodybuf = (char *)malloc(clen + 1);
                if (have > 0) memcpy(bodybuf, bstart, got);
                while (got < clen) { ssize_t k = recv(fd, bodybuf + got, clen - got, 0); if (k <= 0) break; got += (int)k; }
                bodybuf[got] = 0; body = bodybuf; body_len = got;
            }
        }

        pthread_mutex_lock(&s->mtx);
        rctl_rest_cb cb = s->rest_cb; void *cx = s->rest_ctx;
        pthread_mutex_unlock(&s->mtx);
        int status = 200, out_len = 0; const char *out_ctype = NULL;
        char *resp = cb ? cb(cx, method, content_type, path, query, body, body_len,
                             &status, &out_len, &out_ctype) : NULL;
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
        free(resp); free(bodybuf);
        close(fd);
    } else if (strncmp(req, "GET /vendor/", 12) == 0) {
        const char *target = req + 4;
        char rel[256]; size_t ri = 0;
        while (target[ri] && target[ri] != ' ' && ri < sizeof(rel) - 1) { rel[ri] = target[ri]; ri++; }
        rel[ri] = 0;
        if (strstr(rel, "..")) {
            send_text(fd, "400 Bad Request", "text/plain", "bad path");
        } else {
            char path[384];
            snprintf(path, sizeof(path), "/var/mobile/rctl%s", rel);
            size_t len = 0;
            char *body = read_file(path, &len);
            if (body) send_data(fd, "200 OK", ctype_for_path(path), body, len);
            else send_text(fd, "404 Not Found", "text/plain", "not found");
            free(body);
        }
        close(fd);
    } else if (strncmp(req, "GET / ", 6) == 0 || strncmp(req, "GET /index", 10) == 0) {
        size_t hlen = 0;
        char *html = read_file("/var/mobile/rctl/index.html", &hlen);
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
struct rctl_conn { rctl_http_server *s; int fd; };
static void *conn_thread(void *arg) {
    struct rctl_conn *c = (struct rctl_conn *)arg;
    @autoreleasepool {
        handle_client(c->s, c->fd);
    }
    free(c);
    return NULL;
}
static void *accept_loop(void *arg) {
    rctl_http_server *s = (rctl_http_server *)arg;
    while (s->running) {
        struct sockaddr_in ca; socklen_t cl = sizeof(ca);
        int fd = accept(s->listen_fd, (struct sockaddr *)&ca, &cl);
        if (fd < 0) { if (!s->running) break; continue; }
        int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        struct rctl_conn *c = (struct rctl_conn *)malloc(sizeof *c);
        c->s = s; c->fd = fd;
        pthread_t t;
        if (pthread_create(&t, NULL, conn_thread, c) == 0) pthread_detach(t);
        else {
            @autoreleasepool {
                handle_client(s, fd);
            }
            free(c);   // fall back to inline on failure
        }
    }
    return NULL;
}

rctl_http_server *rctl_http_start(int port) {
    signal(SIGPIPE, SIG_IGN);
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) { fprintf(stderr, "[http] socket failed\n"); return NULL; }
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)port);
    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[http] bind %d failed: %s\n", port, strerror(errno));
        close(lfd); return NULL;
    }
    if (listen(lfd, 8) < 0) { fprintf(stderr, "[http] listen failed\n"); close(lfd); return NULL; }

    rctl_http_server *s = (rctl_http_server *)calloc(1, sizeof(rctl_http_server));
    s->listen_fd = lfd; s->port = port; s->running = true; s->orientation = 1;
    s->audio_test_hz = 440;
    for (int i = 0; i < RCTL_MAX_CLIENTS; i++) s->subs[i].fd = -1;
    pthread_mutex_init(&s->mtx, NULL);
    s->audio_thread_started = pthread_create(&s->audio_thread, NULL, audio_test_loop, s) == 0;
    pthread_create(&s->thread, NULL, accept_loop, s);
    fprintf(stderr, "[http] serving on 0.0.0.0:%d\n", port);
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
    s->running = false;
    close(s->listen_fd);
    if (s->audio_thread_started) pthread_join(s->audio_thread, NULL);
    pthread_mutex_lock(&s->mtx);
    for (int i = 0; i < RCTL_MAX_CLIENTS; i++) if (s->subs[i].fd >= 0) sub_close(&s->subs[i]);
    free(s->keyframe);
    pthread_mutex_unlock(&s->mtx);
    free(s);
}
