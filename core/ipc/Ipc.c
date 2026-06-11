#include "ipc/Ipc.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

struct rctl_ipc { int fd; };
struct rctl_ipc_server { int fd; };

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

static bool read_all(int fd, void *buf, size_t n) {
    uint8_t *p = (uint8_t *)buf;
    size_t off = 0;
    while (off < n) {
        ssize_t k = read(fd, p + off, n - off);
        if (k == 0) return false;                       // EOF
        if (k < 0) { if (errno == EINTR) continue; return false; }
        off += (size_t)k;
    }
    return true;
}

static void put_hdr(uint8_t hdr[5], uint8_t type, uint32_t len) {
    hdr[0] = type;
    hdr[1] = (uint8_t)(len >> 24); hdr[2] = (uint8_t)(len >> 16);
    hdr[3] = (uint8_t)(len >> 8);  hdr[4] = (uint8_t)(len);
}

bool rctl_ipc_send(rctl_ipc *c, uint8_t type, const void *data, uint32_t len) {
    if (!c) return false;
    uint8_t hdr[5]; put_hdr(hdr, type, len);
    if (!write_all(c->fd, hdr, 5)) return false;
    if (len && !write_all(c->fd, data, len)) return false;
    return true;
}

bool rctl_ipc_send_prefixed(rctl_ipc *c, uint8_t type, uint8_t prefix,
                            const void *data, uint32_t len) {
    if (!c) return false;
    uint8_t hdr[5]; put_hdr(hdr, type, len + 1);
    if (!write_all(c->fd, hdr, 5)) return false;
    if (!write_all(c->fd, &prefix, 1)) return false;
    if (len && !write_all(c->fd, data, len)) return false;
    return true;
}

bool rctl_ipc_recv(rctl_ipc *c, uint8_t *type, uint8_t **out, uint32_t *len) {
    if (!c) return false;
    uint8_t hdr[5];
    if (!read_all(c->fd, hdr, 5)) return false;
    uint32_t n = ((uint32_t)hdr[1] << 24) | ((uint32_t)hdr[2] << 16) |
                 ((uint32_t)hdr[3] << 8)  |  (uint32_t)hdr[4];
    if (n > (64u << 20)) return false;                  // sanity cap: a desync'd frame
                                                        // length -> drop the connection
    uint8_t *buf = NULL;
    if (n) {
        buf = (uint8_t *)malloc(n);
        if (!buf) return false;
        if (!read_all(c->fd, buf, n)) { free(buf); return false; }
    }
    *type = hdr[0]; *out = buf; *len = n;
    return true;
}

void rctl_ipc_close(rctl_ipc *c) {
    if (!c) return;
    if (c->fd >= 0) close(c->fd);
    free(c);
}

static void fill_addr(struct sockaddr_un *a, const char *path) {
    memset(a, 0, sizeof(*a));
    a->sun_family = AF_UNIX;
    strncpy(a->sun_path, path, sizeof(a->sun_path) - 1);
}

rctl_ipc_server *rctl_ipc_listen(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NULL;
    unlink(path);
    struct sockaddr_un a; fill_addr(&a, path);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return NULL; }
    chmod(path, 0777);                 // SpringBoard runs as mobile; let it connect
    if (listen(fd, 4) < 0) { close(fd); return NULL; }
    rctl_ipc_server *s = (rctl_ipc_server *)calloc(1, sizeof(*s));
    s->fd = fd;
    return s;
}

rctl_ipc *rctl_ipc_accept(rctl_ipc_server *s) {
    if (!s) return NULL;
    int fd = accept(s->fd, NULL, NULL);
    if (fd < 0) return NULL;
    rctl_ipc *c = (rctl_ipc *)calloc(1, sizeof(*c));
    c->fd = fd;
    return c;
}

rctl_ipc *rctl_ipc_connect(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NULL;
    struct sockaddr_un a; fill_addr(&a, path);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return NULL; }
    rctl_ipc *c = (rctl_ipc *)calloc(1, sizeof(*c));
    c->fd = fd;
    return c;
}
