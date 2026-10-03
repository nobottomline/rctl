#pragma once
#include <stddef.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
bool rctl_webrtc_guest_operations_current(const char *owner);
// Called only by the protected bridge. Neither rights nor owner come from the
// browser's RPC payload. Request/reply buffers are borrowed for the call.
typedef void (*rctl_guest_reply)(void *ctx, const char *json);
typedef void (*rctl_guest_request)(const char *owner, double deadline,
    const char *rights, const char *request, size_t len, rctl_guest_reply reply, void *ctx);
void rctl_webrtc_set_guest_operations(rctl_guest_request request,
    bool (*end)(const char *owner), void (*renew)(const char *owner, double deadline));

bool rctl_webrtc_guest_talk_route(const char *owner, int route);

bool rctl_webrtc_guest_text_key(const char *owner, int usage, int down);
#ifdef __cplusplus
}
#endif
