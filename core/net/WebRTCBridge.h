#pragma once
// Device-side WebRTC bridge C-ABI, used by RelayClient.mm (signaling) and
// main.mm (push encoded video / viewer presence). Implemented in WebRTCBridge.cpp.

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// RelayClient registers how to ship an outbound signaling envelope (over the
// /device websocket), and feeds every inbound `webrtc_signal` envelope here.
void rctl_webrtc_set_sender(void (*send)(const char *json));
void rctl_webrtc_handle_signal(const char *json);

// main.mm pushes each Annex-B access unit (the same one it gives /stream) to all
// open WebRTC video channels.
void rctl_webrtc_push_au(const uint8_t *data, size_t len, bool keyframe, uint64_t pts_us);

// Fires when the WebRTC video-viewer count crosses zero, so the daemon keeps the
// capture pipeline awake while a WebRTC viewer is watching (OR-ed with /stream).
void rctl_webrtc_set_viewer_cb(void (*cb)(bool any));

// The browser can ask (via RTCP PLI) for an intra frame; the bridge invokes this
// so the daemon forces the encoder to emit a keyframe.
void rctl_webrtc_set_keyframe_cb(void (*cb)(void));

// The browser sends input (touch/keys) over the WebRTC control DataChannel; the
// bridge decodes it and invokes these so the daemon injects it just like /input.
void rctl_webrtc_set_input_cb(void (*touch)(int phase, int finger, double x, double y),
                              void (*key)(int page, int usage, int down));

#ifdef __cplusplus
}
#endif
