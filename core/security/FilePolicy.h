#pragma once

#include <stddef.h>
#include <sys/stat.h>

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// File-plane protection shared by every path a client can name: the REST file
// handlers (/v1/pull, /v1/push, /v1/rm, /v1/pull_stream) and the owner Files
// DataChannel. Read protection covers secrets; write and delete protection
// covers rctl's own payload, credentials, updater state, and the package
// system trees — the same surfaces the destructive-action list guards. The
// root terminal stays the power-user path by design.
//
// Resolution is component-wise from "/" with O_NOFOLLOW fstatat on every
// step: the policy is evaluated on the path the kernel will actually touch,
// aliases and ".." resolve through the real traversal, and the returned
// descriptors are the ones the caller must operate on — no separate lookup
// can disagree with the open.
#include <fcntl.h>

// Evaluate the write policy for `path` and pin the resolved parent: *dirfd
// receives a descriptor to the verified parent directory (caller closes it),
// *leaf the final component. Returns false when any component is a symlink
// escape, the parent does not resolve, or the verdict denies the write.
bool rctl_file_policy_open_write(const char *path, int *dirfd, char *leaf, size_t leaf_cap);

// Evaluate the read policy and pin the object itself: *fd receives a
// read-only descriptor to a verified regular file (caller closes it).
bool rctl_file_policy_open_read(const char *path, int *fd);

// Evaluate the delete policy and pin the parent: *dirfd receives the verified
// parent descriptor, *leaf the final component; the caller deletes via
// unlinkat(*dirfd, *leaf, ...). Returns false on denial or resolution failure.
bool rctl_file_policy_open_delete(const char *path, int *dirfd, char *leaf, size_t leaf_cap);

#ifdef __cplusplus
}
#endif
