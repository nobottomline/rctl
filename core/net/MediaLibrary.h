#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Performs a Photos-library deletion for one validated ZASSET UUID and returns
// malloc-owned JSON. The daemon wires this to the SpringBoard PhotoKit owner.
typedef char *(*rctl_media_delete_callback)(const char *asset_uuid);
void rctl_media_set_delete_callback(rctl_media_delete_callback callback);

// Handles the /v1/media list, asset metadata, thumbnail, preview, and confirmed
// delete endpoints.
// Returns NULL for unrelated paths. Returned bodies are malloc-owned.
char *rctl_media_handle(const char *path, const char *query, const char *body,
                        int body_len, int *status, int *out_len,
                        const char **out_ctype);

#ifdef __cplusplus
}
#endif
