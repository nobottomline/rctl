#pragma once

#include <stddef.h>

// Destructive operations use a short-lived, one-time token bound to both the
// action and its normalized target. Returned strings are malloc-owned.
char *rctl_destructive_issue(const char *action, const char *target,
                             int *status);
bool rctl_destructive_consume(const char *action, const char *target,
                              const char *token, int *status,
                              char *error, size_t error_len);

// Policy helpers are exposed for host-side regression tests.
bool rctl_destructive_normalize_path(const char *path, char *normalized,
                                     size_t normalized_len);
bool rctl_destructive_path_allowed(const char *path, char *reason,
                                   size_t reason_len);
bool rctl_destructive_package_allowed(const char *package_id,
                                      const char *status_database,
                                      char *reason, size_t reason_len);
