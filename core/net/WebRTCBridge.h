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
void rctl_webrtc_push_audio(const int16_t *pcm, int frames, int channels, int rate, uint64_t pts_us);

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

// File transfer over a dedicated reliable+ordered "files" DataChannel (P2P, so it
// bypasses the relay body cap and streams any size). The browser sends JSON control
// (get/put) + raw binary chunks; the bridge hands each message to this callback
// (is_binary distinguishes a raw chunk from a JSON string). The daemon replies with
// these; rctl_webrtc_files_buffered() exposes the send queue depth for backpressure.
void rctl_webrtc_set_files_cb(void (*cb)(const uint8_t *data, size_t len, int is_binary));
void rctl_webrtc_files_send_text(const char *json);
void rctl_webrtc_files_send_binary(const uint8_t *data, size_t len);
uint64_t rctl_webrtc_files_buffered(void);

// Local (non-relay) signaling: a device-served /ws/signal WebSocket drives the
// same bridge directly. route_session sends a session's outbound offer/ICE to
// (send,ctx) instead of the global relay sender (call BEFORE feeding its "open").
// handle_local_signal wraps a browser {kind,payload} message with the session id
// and dispatches it. unroute_session detaches the sender on disconnect.
void rctl_webrtc_route_session(const char *id, void (*send)(void *ctx, const char *json), void *ctx);
void rctl_webrtc_unroute_session(const char *id);
void rctl_webrtc_handle_local_signal(const char *id, const char *browser_json);

#ifdef __cplusplus
}
#endif
