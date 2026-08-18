#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Handles /v1/media, /v1/media_thumb and /v1/media_asset. Returns NULL when the
// path is not a media-library endpoint. Returned bodies are malloc-owned.
char *rctl_media_handle(const char *path, const char *query, int *status,
                        int *out_len, const char **out_ctype);

#ifdef __cplusplus
}
#endif
