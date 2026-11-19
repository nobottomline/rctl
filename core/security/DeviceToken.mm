#import "DeviceToken.h"

#import <fcntl.h>
#import <errno.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>
#import <sys/types.h>

// The token lives outside the package payload and outside the updater's state
// tree, so installs, upgrades, and rollbacks preserve it. Rootless resolves
// the same literal below the jailbreak prefix.
#import "../platform/Paths.h"

#define RCTL_TOKEN_BYTES 32
#define RCTL_TOKEN_HEX (RCTL_TOKEN_BYTES * 2)

static char g_token[RCTL_TOKEN_HEX + 1];
static char g_hop[RCTL_TOKEN_HEX + 1];

static const char *token_file_path(void) {
    static const char *resolved = RCTL_ROOT_PATH("/var/db/rctl/lan.token");
    return resolved;
}

static void bytes_to_hex(const uint8_t *in, size_t len, char *out /* len*2+1 */) {
    static const char digits[] = "0123456789abcdef";
    for (size_t i = 0; i < len; i++) {
        out[i * 2] = digits[in[i] >> 4];
        out[i * 2 + 1] = digits[in[i] & 0xF];
    }
    out[len * 2] = 0;
}

// Constant-time comparison of two equal-length byte strings; length mismatch
// fails without leaking how far a wrong value matched.
static bool constant_time_equal(const char *a, size_t a_len, const char *b, size_t b_len) {
    volatile const uint8_t *va = (const volatile uint8_t *)a;
    volatile const uint8_t *vb = (const volatile uint8_t *)b;
    uint8_t diff = a_len == b_len ? 0 : 1;
    size_t max = a_len > b_len ? a_len : b_len;
    for (size_t i = 0; i < max; i++) {
        uint8_t x = i < a_len ? va[i] : 0;
        uint8_t y = i < b_len ? vb[i] : 0;
        diff |= (uint8_t)(x ^ y);
    }
    return diff == 0;
}

static bool random_hex(char *out) {
    uint8_t raw[RCTL_TOKEN_BYTES];
    arc4random_buf(raw, sizeof(raw));
    bytes_to_hex(raw, sizeof(raw), out);
    return true;
}

static bool load_token_file(const char *path) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat st = {};
    // A token someone else could read or replace is not the device's secret.
    bool ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size == RCTL_TOKEN_BYTES &&
              st.st_uid == 0 && (st.st_mode & 0777) == 0600;
    if (ok) {
        uint8_t raw[RCTL_TOKEN_BYTES];
        size_t got = 0;
        while (got < sizeof(raw)) {
            ssize_t k = read(fd, (char *)raw + got, sizeof(raw) - got);
            if (k <= 0) { ok = false; break; }
            got += (size_t)k;
        }
        if (ok) bytes_to_hex(raw, sizeof(raw), g_token);
    }
    close(fd);
    return ok;
}

// Atomic first-start creation: write a sibling temp file, fsync, rename, and
// enforce the mode/owner so an interrupted start cannot leave a half token.
static bool create_token_file(const char *path) {
    const char *slash = strrchr(path, '/');
    if (!slash) return false;
    char dir[512];
    size_t dir_len = (size_t)(slash - path);
    if (dir_len >= sizeof(dir)) return false;
    memcpy(dir, path, dir_len);
    dir[dir_len] = 0;
    // Every parent component must exist before the publish; 0700 keeps the
    // secret readable only by root.
    for (char *slash = dir + 1; *slash; slash++) {
        if (*slash != '/') continue;
        *slash = 0;
        if (mkdir(dir, 0700) != 0 && errno != EEXIST) return false;
        *slash = '/';
    }
    if (mkdir(dir, 0700) != 0 && errno != EEXIST) return false;
    if (chmod(dir, 0700) != 0) return false;

    char tmp[576];
    int n = snprintf(tmp, sizeof(tmp), "%s/.lan.token.tmp.%d", dir, getpid());
    if (n < 0 || (size_t)n >= sizeof(tmp)) return false;
    int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return false;
    uint8_t raw[RCTL_TOKEN_BYTES];
    arc4random_buf(raw, sizeof(raw));
    bool ok = true;
    if (write(fd, raw, sizeof(raw)) != (ssize_t)sizeof(raw)) ok = false;
    if (ok && fsync(fd) != 0) ok = false;
    if (ok && fchmod(fd, 0600) != 0) ok = false;
    if (ok && fchown(fd, 0, 0) != 0) ok = false;
    close(fd);
    // link() refuses to replace an existing token: two first starts racing
    // keep exactly one file instead of the loser overwriting the winner.
    if (!ok || link(tmp, path) != 0) {
        unlink(tmp);
        return errno == EEXIST && load_token_file(path);
    }
    unlink(tmp);
    bytes_to_hex(raw, sizeof(raw), g_token);
    return true;
}

bool rctl_device_identity_provision(void) {
    if (!g_hop[0] && !random_hex(g_hop)) return false;
    if (g_token[0]) return true;
    const char *path = token_file_path();
    if (!load_token_file(path)) {
        // A missing file is first start; a malformed or unreadable one is a
        // failure — silently regenerating would strand every paired client.
        struct stat st = {};
        if (lstat(path, &st) == 0) return false;
        if (!create_token_file(path)) return false;
    }
    return g_token[0] != 0;
}

const char *rctl_device_token(void) {
    return g_token[0] ? g_token : NULL;
}

const char *rctl_relay_hop_credential(void) {
    return g_hop[0] ? g_hop : NULL;
}

bool rctl_device_token_matches(const char *presented) {
    const char *token = rctl_device_token();
    if (!token || !presented) return false;
    return constant_time_equal(token, RCTL_TOKEN_HEX, presented, strlen(presented));
}

bool rctl_relay_hop_matches(const char *presented) {
    if (!g_hop[0] || !presented) return false;
    return constant_time_equal(g_hop, RCTL_TOKEN_HEX, presented, strlen(presented));
}
