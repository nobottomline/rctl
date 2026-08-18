#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Handles the /v1/media list, asset metadata, thumbnail, and preview endpoints.
// Returns NULL for unrelated paths. Returned bodies are malloc-owned.
char *rctl_media_handle(const char *path, const char *query, int *status,
                        int *out_len, const char **out_ctype);

#ifdef __cplusplus
}
#endif
