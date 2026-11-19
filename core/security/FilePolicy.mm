#import "FilePolicy.h"

#import <fcntl.h>
#import <limits.h>
#import <pthread.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>

#import "../platform/Paths.h"

// rctl infrastructure that must never be readable or replaceable through the
// file API: the LAN token, the relay credential store (and its update-time
// preserve copy), and the updater state tree with its rollback backups.
static const char *const kSecretFiles[] = {
    "/var/db/rctl",
    // The update tree holds the updater's relay-credential backup copies for
    // the duration of a transaction.
    "/var/mobile/Library/Caches/com.greatlove.rctl",
    "/var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist",
    "/tmp/com.greatlove.rctl.relay.plist.rctl-preserve",
};

// Package payload, credential, and package-system trees that writes and
// deletes must not touch. Each entry is also checked below the rootless
// prefix, so the resolved bootstrap payload is covered in both layouts.
static const char *const kWriteProtected[] = {
    "/var/db/rctl",
    "/var/mobile/rctl",
    "/var/mobile/Library/Caches/com.greatlove.rctl",
    "/var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist",
    "/tmp/com.greatlove.rctl.relay.plist.rctl-preserve",
    "/usr",
    "/Library",
    "/etc",
    "/var/jb",
    "/var/lib/dpkg",
    "/var/lib/apt",
    "/usr/local/share/rctl",
    "/usr/local/bin/rctld",
    "/usr/local/libexec/rctl-updater",
    "/Library/LaunchDaemons/com.greatlove.rctld.plist",
    "/Library/MobileSubstrate/DynamicLibraries/rctl",
};

static bool path_is_under(const char *path, size_t path_len, const char *root) {
    size_t root_len = strlen(root);
    if (path_len < root_len) return false;
    if (memcmp(path, root, root_len) != 0) return false;
    // A prefix boundary must fall on a component: "/var/jb2" is not "/var/jb".
    return path_len == root_len || path[root_len] == '/';
}

// The resolved rootless prefix, derived from the same RCTL_ROOT_PATH literal
// the destructive-action policy uses. Rootful yields "" (every protected root
// is already absolute).
static const char *jb_prefix(void) {
    static char prefix[PATH_MAX];
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, [] {
        const char *usr = RCTL_ROOT_PATH("/usr");
        size_t len = strlen(usr);
        if (len >= 4 && strcmp(usr + len - 4, "/usr") == 0) {
            memcpy(prefix, usr, len - 4);
            prefix[len - 4] = 0;
        } else {
            prefix[0] = 0;
        }
    });
    return prefix;
}

// Normalize a candidate the way the kernel resolves it for the comparisons we
// can do textually: collapse duplicate slashes and "." components, resolve
// ".." against the leading components, and fold the /private alias of /var
// and /etc. Symlinks and existing-object identity are handled separately.
static bool normalize_path(const char *input, char *out, size_t cap) {
    if (!input || input[0] != '/') return false;
    const char *aliases[][2] = { { "/private/var/", "/var/" }, { "/private/var", "/var" },
                                 { "/private/etc/", "/etc/" }, { "/private/etc", "/etc" },
                                 { "/private/tmp/", "/tmp/" }, { "/private/tmp", "/tmp" },
                                 { "/private/home/", "/home/" }, { "/private/home", "/home" } };
    char staged[4 * PATH_MAX];
    if (strlen(input) >= sizeof(staged)) return false;
    strcpy(staged, input);
    for (size_t round = 0; round < 4; round++) {
        bool changed = false;
        for (size_t i = 0; i < sizeof(aliases) / sizeof(aliases[0]); i++) {
            const char *from = aliases[i][0];
            const char *to = aliases[i][1];
            size_t from_len = strlen(from);
            if (strncmp(staged, from, from_len) == 0) {
                char merged[4 * PATH_MAX];
                snprintf(merged, sizeof(merged), "%s%s", to, staged + from_len);
                strcpy(staged, merged);
                changed = true;
            }
        }
        if (!changed) break;
    }
    // Component-wise resolution of "." and ".." without touching the filesystem.
    char *parts[256];
    size_t count = 0;
    char buffer[4 * PATH_MAX];
    strcpy(buffer, staged);
    char *save = NULL;
    for (char *tok = strtok_r(buffer, "/", &save); tok; tok = strtok_r(NULL, "/", &save)) {
        if (!strcmp(tok, ".")) continue;
        if (!strcmp(tok, "..")) {
            if (count == 0) return false;  // escaping the root
            count--;
            continue;
        }
        if (count >= sizeof(parts) / sizeof(parts[0])) return false;
        parts[count++] = tok;
    }
    size_t used = 0;
    if (used + 1 >= cap) return false;
    out[used++] = '/';
    out[used] = 0;
    for (size_t i = 0; i < count; i++) {
        size_t len = strlen(parts[i]);
        if (used + len + 2 > cap) return false;
        if (used > 1) out[used++] = '/';
        memcpy(out + used, parts[i], len);
        used += len;
        out[used] = 0;
    }
    // A trailing slash carries no meaning for a file operation.
    size_t out_len = strlen(out);
    while (out_len > 1 && out[out_len - 1] == '/') out[--out_len] = 0;
    return true;
}

static bool denied_for(const char *input, const char *const *roots, size_t root_count) {
    char canonical[PATH_MAX];
    if (!normalize_path(input, canonical, sizeof(canonical))) return true;  // fail closed
    size_t canonical_len = strlen(canonical);
    for (size_t i = 0; i < root_count; i++) {
        if (path_is_under(canonical, canonical_len, roots[i])) return true;
    }
    // Rootless layouts resolve every protected root below the actual jailbreak
    // prefix too. The prefix is derived from the resolved /usr literal (the
    // same convention the destructive-action policy uses), never assumed.
    const char *jb = jb_prefix();
    for (size_t i = 0; jb[0] && i < root_count; i++) {
        char rooted[2 * PATH_MAX];
        int n = snprintf(rooted, sizeof(rooted), "%s%s", jb, roots[i]);
        if (n < 0 || (size_t)n >= sizeof(rooted)) continue;
        if (path_is_under(canonical, canonical_len, rooted)) return true;
    }
    // What exists on disk decides under its real name: an alias or symlink
    // must not carry a path out of a protected tree. The real path is folded
    // through the same normalization as the candidate, because Darwin realpath
    // may answer in its /private/var spelling while the roots are written as
    // /var.
    char real[PATH_MAX];
    if (realpath(input, real)) {
        char real_canonical[PATH_MAX];
        const char *real_cmp = real;
        if (normalize_path(real, real_canonical, sizeof(real_canonical))) real_cmp = real_canonical;
        size_t real_len = strlen(real_cmp);
        for (size_t i = 0; i < root_count; i++) {
            if (path_is_under(real_cmp, real_len, roots[i])) return true;
            char rooted[2 * PATH_MAX];
            int n = snprintf(rooted, sizeof(rooted), "%s%s", jb, roots[i]);
            if (n < 0 || (size_t)n >= sizeof(rooted)) continue;
            if (path_is_under(real_cmp, real_len, rooted)) return true;
        }
        return false;   // the object exists outside every protected tree
    }
    // A not-yet-existing target would be created inside its parent: the
    // parent's real location decides, so a planted ancestor symlink cannot
    // move the creation point out of a protected tree.
    char dir_copy[PATH_MAX];
    snprintf(dir_copy, sizeof(dir_copy), "%s", canonical);
    char *last_slash = strrchr(dir_copy, '/');
    if (!last_slash || last_slash == dir_copy) return false;
    *last_slash = 0;
    char parent_real[PATH_MAX];
    if (!realpath(dir_copy, parent_real)) return true;   // unresolvable parent: fail closed
    char parent_canonical[PATH_MAX];
    const char *parent_cmp = parent_real;
    if (normalize_path(parent_real, parent_canonical, sizeof(parent_canonical))) parent_cmp = parent_canonical;
    size_t parent_len = strlen(parent_cmp);
    for (size_t i = 0; i < root_count; i++) {
        if (path_is_under(parent_cmp, parent_len, roots[i])) return true;
        char rooted[2 * PATH_MAX];
        int n = snprintf(rooted, sizeof(rooted), "%s%s", jb, roots[i]);
        if (n < 0 || (size_t)n >= sizeof(rooted)) continue;
        if (path_is_under(parent_cmp, parent_len, rooted)) return true;
    }
    return false;
}

bool rctl_file_policy_read_denied(const char *path) {
    static const size_t count = sizeof(kSecretFiles) / sizeof(kSecretFiles[0]);
    return denied_for(path, kSecretFiles, count);
}

bool rctl_file_policy_write_denied(const char *path) {
    static const size_t count = sizeof(kWriteProtected) / sizeof(kWriteProtected[0]);
    return denied_for(path, kWriteProtected, count);
}

bool rctl_file_policy_delete_denied(const char *path) {
    return rctl_file_policy_write_denied(path);
}

#import <pthread.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <string.h>

// On iOS the top-level /var, /tmp, and /etc are symlinks into /private/*.
// Fold them textually BEFORE the walk so the component-wise resolution below
// never needs to follow a symlink, yet still lands on the same objects the
// kernel would resolve. The built real path therefore starts at /private.
static bool fold_aliases(const char *path, char *folded, size_t cap) {
    if (!path || path[0] != '/') return false;
    // Pre-normalize the leading spelling so every alias form reaches the walk
    // identically: collapse duplicate slashes and "/./", and strip a trailing
    // slash (a directory request is the same object without it).
    char collapsed[PATH_MAX];
    {
        size_t ri = 0;
        size_t total = strlen(path);
        for (size_t i = 0; i < total; i++) {
            if (ri + 1 >= sizeof(collapsed)) return false;   // oversized: reject, never truncate
            if (path[i] == '/' && path[i + 1] == '/') continue;
            if (path[i] == '/' && path[i + 1] == '.' && path[i + 2] == '/' && i + 2 < total) { i++; continue; }
            collapsed[ri++] = path[i];
        }
        collapsed[ri] = 0;
        size_t len = ri;
        while (len > 1 && collapsed[len - 1] == '/') collapsed[--len] = 0;
        if (len == 0) { collapsed[0] = '/'; collapsed[1] = 0; }
    }
    path = collapsed;
    static const char *const tops[] = { "/var", "/tmp", "/etc", "/home" };
    for (size_t i = 0; i < sizeof(tops) / sizeof(tops[0]); i++) {
        const char *top = tops[i];
        size_t top_len = strlen(top);
        size_t plen = strlen(path);
        bool exact = plen == top_len && strcmp(path, top) == 0;
        bool under = plen > top_len && strncmp(path, top, top_len) == 0 && path[top_len] == '/';
        if (!exact && !under) continue;
        int n = snprintf(folded, cap, "/private%s%s", top, under ? path + top_len : "");
        return n >= 0 && (size_t)n < cap;
    }
    if (strlen(path) >= cap) return false;
    strcpy(folded, path);
    return true;
}

#define WALK_MAX_STEPS 64
#define WALK_MAX_NAME 255

typedef enum { WALK_OBJECT, WALK_PARENT } walk_mode;

// Resolve `folded` component-wise from the pinned "/" anchor. Every directory
// is opened with openat from the previous descriptor, so no ancestor can be
// swapped between resolution and use; ".." is resolved by the kernel relative
// to the pinned directory and the built real path follows the traversal.
// WALK_OBJECT pins the final component's own descriptor (caller checks its
// type); WALK_PARENT stops at the parent and reports the final component's
// name, which need not exist. `real` receives the traversed path in the
// kernel's own spelling. Symlinks anywhere below "/" are refused.
static bool walk_pinned(const char *folded, walk_mode mode, int *pinned,
                        char *leaf_out, size_t leaf_cap,
                        char *real, size_t real_cap) {
    *pinned = -1;
    if (leaf_out && leaf_cap) leaf_out[0] = 0;
    int dir = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dir < 0) return false;
    // Identity of each directory on the traversed chain, captured at descent
    // time: the ascent must return to the object recorded when we left it.
    struct { dev_t dev; ino_t ino; } chain[WALK_MAX_STEPS + 1];
    int depth = 0;
    struct stat anchor_st = {};
    if (fstat(dir, &anchor_st) != 0) { close(dir); return false; }
    chain[depth].dev = anchor_st.st_dev;
    chain[depth].ino = anchor_st.st_ino;
    size_t used = 0;
    real[used++] = '/';
    real[used] = 0;
    const char *p = folded + 1;
    int steps = 0;
    for (;;) {
        while (*p == '/') p++;
        if (*p == 0) {
            // Ended on a directory: WALK_OBJECT pins it, WALK_PARENT has no leaf.
            if (mode == WALK_OBJECT) { *pinned = dir; return true; }
            close(dir);
            return false;                        // a directory is not a leaf
        }
        const char *end = p;
        while (*end && *end != '/') end++;
        size_t len = (size_t)(end - p);
        if (len == 0 || len > WALK_MAX_NAME) { close(dir); return false; }
        if (++steps > WALK_MAX_STEPS) { close(dir); return false; }
        bool last = *end == 0;
        char component[WALK_MAX_NAME + 1];
        memcpy(component, p, len);
        component[len] = 0;

        if (strcmp(component, ".") == 0) {
            // Same directory.
        } else if (strcmp(component, "..") == 0) {
            if (depth == 0) { close(dir); return false; }   // above the root
            // Ascend relative to the pinned descriptor; the ascended object
            // must be the parent recorded when we descended INTO the current
            // directory. A concurrent cross-parent rename (before or between
            // the calls) makes the identities disagree and the walk refuses,
            // so the recorded path — which drives the verdict — cannot
            // re-point to a different object than the descriptor.
            int up = openat(dir, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (up < 0) { close(dir); return false; }
            struct stat ascended = {};
            if (fstat(up, &ascended) != 0 ||
                ascended.st_dev != chain[depth - 1].dev ||
                ascended.st_ino != chain[depth - 1].ino) {
                close(up);
                close(dir);
                return false;
            }
            close(dir);
            dir = up;
            depth--;
            // Drop exactly the last recorded component ("/a/b" -> "/a") without
            // losing a one-character name and without leaving a trailing
            // slash that would confuse a following ".." step.
            size_t cut = used;
            while (cut > 1 && real[cut - 1] != '/') cut--;
            used = cut > 1 ? cut - 1 : 1;
            if (used > 1) {
                while (used > 1 && real[used - 1] == '/') used--;
                real[used] = 0;
            } else {
                used = 1;
                real[1] = 0;
            }
        } else {
            if (mode == WALK_PARENT && last) {
                // The leaf need not exist: pin its parent and report the name.
                size_t len_real = strlen(component);
                if (used + len_real + 2 > real_cap || len >= leaf_cap) { close(dir); return false; }
                if (used > 1) real[used++] = '/';
                memcpy(real + used, component, len_real);
                used += len_real;
                real[used] = 0;
                snprintf(leaf_out, leaf_cap, "%s", component);
                *pinned = dir;
                return true;
            }
            struct stat st = {};
            if (fstatat(dir, component, &st, AT_SYMLINK_NOFOLLOW) != 0) { close(dir); return false; }
            if (S_ISLNK(st.st_mode)) { close(dir); return false; }
            if (last && mode == WALK_OBJECT) {
                int object = openat(dir, component, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
                close(dir);
                if (object < 0) return false;
                if (used + len + 2 > real_cap) { close(object); return false; }
                if (used > 1) real[used++] = '/';
                memcpy(real + used, component, len);
                real[used + len] = 0;
                *pinned = object;
                return true;
            }
            if (!S_ISDIR(st.st_mode)) { close(dir); return false; }
            int next = openat(dir, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (next < 0) { close(dir); return false; }
            close(dir);
            dir = next;
            struct stat next_st = {};
            if (fstat(dir, &next_st) != 0 || depth >= WALK_MAX_STEPS) { close(dir); return false; }
            depth++;
            chain[depth].dev = next_st.st_dev;
            chain[depth].ino = next_st.st_ino;
            size_t len_real = strlen(component);
            if (used + len_real + 2 > real_cap) { close(dir); return false; }
            if (used > 1) real[used++] = '/';
            memcpy(real + used, component, len_real);
            used += len_real;
            real[used] = 0;
        }
        if (last) {
            // A trailing slash or a "."/".." ending on a directory.
            if (mode == WALK_OBJECT) { *pinned = dir; return true; }
            close(dir);
            return false;
        }
        p = end;
    }
}

// Evaluate the write policy for `path` and pin the resolved parent: *dirfd
// receives a descriptor to the verified parent directory (caller closes it)
// and leaf_out the final component. The verdict covers the path the kernel
// resolves — symlink ancestors and ".." included.
bool rctl_file_policy_open_write(const char *path, int *dirfd, char *leaf_out, size_t leaf_cap) {
    if (!dirfd || !leaf_out) return false;
    char real[PATH_MAX], folded[PATH_MAX];
    char leaf[WALK_MAX_NAME + 1];
    int pinned = -1;
    if (!fold_aliases(path, folded, sizeof(folded)) ||
        !walk_pinned(folded, WALK_PARENT, &pinned, leaf, sizeof(leaf), real, sizeof(real))) {
        if (pinned >= 0) close(pinned);
        return false;
    }
    // The traversed real path already ends at the leaf; the verdict covers
    // the exact name the caller will create, and the raw request is checked
    // too so an unfolded spelling cannot ride a policy gap.
    if (rctl_file_policy_write_denied(real) || rctl_file_policy_write_denied(path)) {
        close(pinned);
        return false;
    }
    snprintf(leaf_out, leaf_cap, "%s", leaf);
    *dirfd = pinned;
    return true;
}

// Evaluate the read policy and pin the object itself: *fd receives a
// read-only descriptor to a verified regular file with no other links.
bool rctl_file_policy_open_read(const char *path, int *fd) {
    if (!fd) return false;
    char real[PATH_MAX], folded[PATH_MAX];
    int object = -1;
    if (!fold_aliases(path, folded, sizeof(folded)) ||
        !walk_pinned(folded, WALK_OBJECT, &object, NULL, 0, real, sizeof(real))) {
        if (object >= 0) close(object);
        return false;
    }
    struct stat st = {};
    if (fstat(object, &st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink > 1 ||
        rctl_file_policy_read_denied(real) || rctl_file_policy_read_denied(path)) {
        close(object);
        return false;
    }
    *fd = object;
    return true;
}

// Evaluate the delete policy and pin the parent: *dirfd receives the verified
// parent descriptor and leaf_out the final component (which may be a
// directory the caller removes with AT_REMOVEDIR).
bool rctl_file_policy_open_delete(const char *path, int *dirfd, char *leaf_out, size_t leaf_cap) {
    if (!dirfd || !leaf_out) return false;
    char real[PATH_MAX], folded[PATH_MAX];
    char leaf[WALK_MAX_NAME + 1];
    int pinned = -1;
    if (!fold_aliases(path, folded, sizeof(folded)) ||
        !walk_pinned(folded, WALK_PARENT, &pinned, leaf, sizeof(leaf), real, sizeof(real))) {
        if (pinned >= 0) close(pinned);
        return false;
    }
    if (rctl_file_policy_delete_denied(real) || rctl_file_policy_delete_denied(path)) {
        close(pinned);
        return false;
    }
    snprintf(leaf_out, leaf_cap, "%s", leaf);
    *dirfd = pinned;
    return true;
}
