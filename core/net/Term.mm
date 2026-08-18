// Term.mm — WebSocket-backed root PTY terminal.
//
// Browser -> daemon binary frames:
//   [1][UTF-8 input bytes]                     write to PTY
//   [2][2B BE cols][2B BE rows]                resize PTY
// Daemon -> browser binary frames:
//   raw PTY bytes, including ANSI colors and cursor-control sequences.

#import "net/Term.h"
#import "net/WebRTCBridge.h"
#import <CommonCrypto/CommonDigest.h>
#import <pthread.h>
#import <sys/ioctl.h>
#import <sys/socket.h>
#import <sys/wait.h>
#import <termios.h>
#import <util.h>
#import <unistd.h>
#import <errno.h>
#import <signal.h>
#import <stdlib.h>
#import <stdio.h>
#import <string.h>

struct term_session {
    int ws_fd;
    int pty_fd;
    pid_t child;
    volatile bool running;
    pthread_mutex_t send_mtx;
};

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

static bool recv_full_plain(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t r = recv(fd, p + off, len - off, 0);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; return false; }
        off += (size_t)r;
    }
    return true;
}

static bool header_value(const char *req, const char *name, char *out, size_t out_len) {
    size_t name_len = strlen(name);
    const char *p = req;
    while ((p = strstr(p, "\r\n")) != NULL) {
        p += 2;
        if (*p == '\r' || *p == '\n' || !*p) break;
        if (strncasecmp(p, name, name_len) == 0 && p[name_len] == ':') {
            p += name_len + 1;
            while (*p == ' ' || *p == '\t') p++;
            size_t n = 0;
            while (p[n] && !(p[n] == '\r' && p[n + 1] == '\n') && n + 1 < out_len) {
                out[n] = p[n];
                n++;
            }
            out[n] = 0;
            return true;
        }
    }
    if (out_len) out[0] = 0;
    return false;
}

static char *base64_encode(const uint8_t *data, size_t len) {
    static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t out_len = ((len + 2) / 3) * 4;
    char *out = (char *)malloc(out_len + 1);
    if (!out) return NULL;
    size_t i = 0, j = 0;
    while (i < len) {
        uint32_t a = i < len ? data[i++] : 0;
        uint32_t b = i < len ? data[i++] : 0;
        uint32_t c = i < len ? data[i++] : 0;
        uint32_t v = (a << 16) | (b << 8) | c;
        out[j++] = tbl[(v >> 18) & 63];
        out[j++] = tbl[(v >> 12) & 63];
        out[j++] = tbl[(v >> 6) & 63];
        out[j++] = tbl[v & 63];
    }
    size_t rem = len % 3;
    if (rem) {
        out[out_len - 1] = '=';
        if (rem == 1) out[out_len - 2] = '=';
    }
    out[out_len] = 0;
    return out;
}

static char *ws_accept_key(const char *client_key) {
    char buf[256];
    snprintf(buf, sizeof(buf), "%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", client_key);
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(buf, (CC_LONG)strlen(buf), digest);
    return base64_encode(digest, sizeof(digest));
}

static bool ws_send_frame(int fd, uint8_t opcode, const void *data, size_t len) {
    uint8_t hdr[10];
    size_t hn = 0;
    hdr[hn++] = 0x80 | (opcode & 0x0f);
    if (len < 126) {
        hdr[hn++] = (uint8_t)len;
    } else if (len <= 65535) {
        hdr[hn++] = 126;
        hdr[hn++] = (uint8_t)(len >> 8);
        hdr[hn++] = (uint8_t)len;
    } else {
        hdr[hn++] = 127;
        for (int i = 7; i >= 0; i--) hdr[hn++] = (uint8_t)((uint64_t)len >> (i * 8));
    }
    return send_full(fd, hdr, hn) && (len == 0 || send_full(fd, data, len));
}

static bool ws_recv_frame(int fd, uint8_t *opcode, uint8_t **payload, size_t *payload_len) {
    uint8_t h[2];
    if (!recv_full_plain(fd, h, 2)) return false;
    *opcode = h[0] & 0x0f;
    bool masked = (h[1] & 0x80) != 0;
    uint64_t len = h[1] & 0x7f;
    if (len == 126) {
        uint8_t x[2];
        if (!recv_full_plain(fd, x, 2)) return false;
        len = ((uint64_t)x[0] << 8) | x[1];
    } else if (len == 127) {
        uint8_t x[8];
        if (!recv_full_plain(fd, x, 8)) return false;
        len = 0;
        for (int i = 0; i < 8; i++) len = (len << 8) | x[i];
    }
    if (len > (1 << 20)) return false;
    uint8_t mask[4] = {0, 0, 0, 0};
    if (masked && !recv_full_plain(fd, mask, 4)) return false;
    uint8_t *p = (uint8_t *)malloc((size_t)len + 1);
    if (!p) return false;
    if (len && !recv_full_plain(fd, p, (size_t)len)) { free(p); return false; }
    if (masked) for (uint64_t i = 0; i < len; i++) p[i] ^= mask[i & 3];
    p[len] = 0;
    *payload = p;
    *payload_len = (size_t)len;
    return true;
}

static bool term_send(struct term_session *t, const void *data, size_t len) {
    pthread_mutex_lock(&t->send_mtx);
    bool ok = ws_send_frame(t->ws_fd, 2, data, len);
    pthread_mutex_unlock(&t->send_mtx);
    return ok;
}

static void term_resize(struct term_session *t, uint16_t cols, uint16_t rows) {
    if (cols < 20) cols = 20;
    if (rows < 5) rows = 5;
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = cols;
    ws.ws_row = rows;
    ioctl(t->pty_fd, TIOCSWINSZ, &ws);
}

static void *term_pty_loop(void *arg) {
    struct term_session *t = (struct term_session *)arg;
    uint8_t buf[4096];
    while (t->running) {
        ssize_t n = read(t->pty_fd, buf, sizeof(buf));
        if (n <= 0) { if (n < 0 && errno == EINTR) continue; break; }
        if (!term_send(t, buf, (size_t)n)) break;
    }
    t->running = false;
    shutdown(t->ws_fd, SHUT_RDWR);
    return NULL;
}

static bool spawn_term(struct term_session *t, uint16_t cols, uint16_t rows) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = cols ? cols : 100;
    ws.ws_row = rows ? rows : 30;
    pid_t pid = forkpty(&t->pty_fd, NULL, NULL, &ws);
    if (pid < 0) return false;
    if (pid == 0) {
        setenv("TERM", "xterm-256color", 1);
        setenv("HOME", "/var/root", 1);
        setenv("USER", "root", 1);
        setenv("LOGNAME", "root", 1);
        setenv("SHELL", "/bin/sh", 1);
        setenv("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1);
        chdir("/var/root");
        execl("/bin/sh", "-sh", NULL);
        _exit(127);
    }
    t->child = pid;
    return true;
}

void rctl_term_handle_ws(int fd, const char *req) {
    char key[160];
    if (!header_value(req, "Sec-WebSocket-Key", key, sizeof(key))) {
        const char *body = "missing websocket key";
        char h[160];
        int n = snprintf(h, sizeof(h),
            "HTTP/1.1 400 Bad Request\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n",
            strlen(body));
        send_full(fd, h, (size_t)n);
        send_full(fd, body, strlen(body));
        close(fd);
        return;
    }

    char *accept = ws_accept_key(key);
    if (!accept) { close(fd); return; }
    char resp[512];
    int rn = snprintf(resp, sizeof(resp),
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Accept: %s\r\n"
        "Cache-Control: no-cache\r\n\r\n", accept);
    free(accept);
    if (!send_full(fd, resp, (size_t)rn)) { close(fd); return; }

    uint16_t cols = 100, rows = 30;
    const char *p;
    if ((p = strstr(req, "cols="))) cols = (uint16_t)atoi(p + 5);
    if ((p = strstr(req, "rows="))) rows = (uint16_t)atoi(p + 5);

    struct term_session t;
    memset(&t, 0, sizeof(t));
    t.ws_fd = fd;
    t.pty_fd = -1;
    t.child = -1;
    t.running = true;
    pthread_mutex_init(&t.send_mtx, NULL);
    if (!spawn_term(&t, cols, rows)) {
        const char *msg = "failed to start shell\r\n";
        ws_send_frame(fd, 2, msg, strlen(msg));
        close(fd);
        pthread_mutex_destroy(&t.send_mtx);
        return;
    }

    const char *hello = "\033[32mrctl root terminal\033[0m\r\n";
    term_send(&t, hello, strlen(hello));
    pthread_t out_thread;
    if (pthread_create(&out_thread, NULL, term_pty_loop, &t) == 0) pthread_detach(out_thread);
    else t.running = false;

    while (t.running) {
        uint8_t op = 0;
        uint8_t *payload = NULL;
        size_t len = 0;
        if (!ws_recv_frame(fd, &op, &payload, &len)) break;
        if (op == 0x8) { free(payload); break; }
        if (op == 0x9) {
            pthread_mutex_lock(&t.send_mtx);
            ws_send_frame(fd, 0xA, payload, len);
            pthread_mutex_unlock(&t.send_mtx);
            free(payload);
            continue;
        }
        if ((op == 0x2 || op == 0x1) && len > 0) {
            if (payload[0] == 1 && len > 1) {
                (void)write(t.pty_fd, payload + 1, len - 1);
            } else if (payload[0] == 2 && len >= 5) {
                uint16_t c = (uint16_t)((payload[1] << 8) | payload[2]);
                uint16_t r = (uint16_t)((payload[3] << 8) | payload[4]);
                term_resize(&t, c, r);
            }
        }
        free(payload);
    }

    t.running = false;
    if (t.child > 0) {
        kill(t.child, SIGHUP);
        int st = 0;
        waitpid(t.child, &st, WNOHANG);
    }
    if (t.pty_fd >= 0) close(t.pty_fd);
    close(fd);
    pthread_mutex_destroy(&t.send_mtx);
}

// ---- WebRTC local signaling over WebSocket (/ws/signal) --------------------
// A LAN browser drives the device's WebRTC bridge directly (no relay). The
// device is the offerer with an empty ICE list (host-only candidates), so media
// flows P2P-direct over the LAN -- relay-grade video without the relay. Mirrors
// the relay's signaling envelopes, routed over this socket instead.

struct signal_session {
    int ws_fd;
    pthread_mutex_t send_mtx;
};

// Bridge -> browser: ship an outbound envelope as a WS text frame. Invoked from a
// libdatachannel worker thread, so it serializes writes against this socket.
static void signal_ws_send(void *ctx, const char *json) {
    struct signal_session *s = (struct signal_session *)ctx;
    if (!s || !json) return;
    pthread_mutex_lock(&s->send_mtx);
    ws_send_frame(s->ws_fd, 0x1, json, strlen(json));
    pthread_mutex_unlock(&s->send_mtx);
}

void rctl_signal_handle_ws(int fd, const char *req) {
    char key[160];
    if (!header_value(req, "Sec-WebSocket-Key", key, sizeof(key))) {
        const char *body = "missing websocket key";
        char h[160];
        int n = snprintf(h, sizeof(h),
            "HTTP/1.1 400 Bad Request\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n",
            strlen(body));
        send_full(fd, h, (size_t)n);
        send_full(fd, body, strlen(body));
        close(fd);
        return;
    }
    char *accept = ws_accept_key(key);
    if (!accept) { close(fd); return; }
    char resp[512];
    int rn = snprintf(resp, sizeof(resp),
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Accept: %s\r\n"
        "Cache-Control: no-cache\r\n\r\n", accept);
    free(accept);
    if (!send_full(fd, resp, (size_t)rn)) { close(fd); return; }

    static unsigned long s_counter = 0;
    static pthread_mutex_t s_counter_mtx = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&s_counter_mtx);
    unsigned long seq = ++s_counter;
    pthread_mutex_unlock(&s_counter_mtx);
    bool camera = strstr(req, "GET /ws/signal?media=camera ") != NULL;
    char id[48];
    snprintf(id, sizeof(id), camera ? "lcam_%d_%lu" : "lws_%d_%lu", fd, seq);

    struct signal_session s;
    s.ws_fd = fd;
    pthread_mutex_init(&s.send_mtx, NULL);

    // Route this session's outbound envelopes to our socket, THEN trigger the
    // device offer with an empty ICE list (host-only -> direct LAN).
    rctl_webrtc_route_session(id, signal_ws_send, &s);
    char openmsg[192];
    snprintf(openmsg, sizeof(openmsg),
             "{\"type\":\"webrtc_signal\",\"id\":\"%s\",\"kind\":\"open\",\"payload\":{\"role\":\"%s\",\"ice\":[]}}",
             id, camera ? "camera" : "screen");
    rctl_webrtc_handle_signal(openmsg);

    for (;;) {
        uint8_t op = 0;
        uint8_t *payload = NULL;
        size_t len = 0;
        if (!ws_recv_frame(fd, &op, &payload, &len)) break;
        if (op == 0x8) { free(payload); break; }
        if (op == 0x9) {
            pthread_mutex_lock(&s.send_mtx);
            ws_send_frame(fd, 0xA, payload, len);
            pthread_mutex_unlock(&s.send_mtx);
            free(payload);
            continue;
        }
        if ((op == 0x1 || op == 0x2) && len > 0) {
            rctl_webrtc_handle_local_signal(id, (const char *)payload);
        }
        free(payload);
    }

    // Tear down in an order that can't race the bridge's worker threads: closing
    // the session detaches all its callbacks (and blocks until none are in
    // flight), so afterwards no thread can call signal_ws_send on this fd/ctx.
    char closemsg[128];
    snprintf(closemsg, sizeof(closemsg),
             "{\"type\":\"webrtc_signal\",\"id\":\"%s\",\"kind\":\"close\"}", id);
    rctl_webrtc_handle_signal(closemsg);
    rctl_webrtc_unroute_session(id);
    close(fd);
    pthread_mutex_destroy(&s.send_mtx);
}
