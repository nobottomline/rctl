#pragma once

#import <stddef.h>
#import <stdint.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rctl_http_server rctl_http_server;

// Start an HTTP server on `port` (0.0.0.0). Serves a WebCodecs player at "/" and
// a live H.264 stream at "/stream". Returns NULL on failure.
rctl_http_server *rctl_http_start(int port);

// Push one Annex-B access unit to all connected stream clients. `pts_us` is a
// microsecond presentation timestamp relative to the current capture session.
void rctl_http_push_au(rctl_http_server *s, const uint8_t *data, size_t len,
                       bool keyframe, uint64_t pts_us);

// Push one interleaved signed 16-bit little-endian PCM packet to all connected
// stream clients. The payload is carried as stream frame type 4:
// [8B BE pts_us][4B BE sample_rate][1B channels][1B bytes_per_sample]
// [2B BE frames][interleaved s16le PCM].
void rctl_http_push_pcm_s16le(rctl_http_server *s, const int16_t *samples,
                              uint16_t frames, uint8_t channels,
                              uint32_t sample_rate, uint64_t pts_us);

// Set the current display orientation (UIInterfaceOrientation: 1=portrait,
// 2=portrait-upside-down, 3=landscape-right, 4=landscape-left). Broadcast to clients.
void rctl_http_set_orientation(rctl_http_server *s, int orientation);

// Tell clients to drop their decoder (used around an encoder reconfigure, since
// the resolution/SPS changes). Also clears the cached keyframe.
void rctl_http_signal_reset(rctl_http_server *s);

// Register a callback invoked when a client requests new encode settings via
// GET /config?fps=..&scale=..&bitrate=..
typedef void (*rctl_reconfigure_cb)(void *ctx, int fps, double scale, int bitrate);
void rctl_http_set_reconfigure(rctl_http_server *s, rctl_reconfigure_cb cb, void *ctx);

// Register a callback invoked for client input via GET /input?phase=&id=&x=&y=
// phase: 0=down,1=move,2=up; (x,y) normalized [0,1] in framebuffer space.
typedef void (*rctl_input_cb)(void *ctx, int phase, int finger, double nx, double ny);
void rctl_http_set_input(rctl_http_server *s, rctl_input_cb cb, void *ctx);

// Register a callback for client key/button input via GET /key?p=<page>&u=<usage>&d=<0|1>
// page defaults to 0x07 (keyboard); 0x0C = Consumer (Home/Power/Volume).
typedef void (*rctl_key_cb)(void *ctx, int page, int usage, int down);
void rctl_http_set_key(rctl_http_server *s, rctl_key_cb cb, void *ctx);

// Register a handler for the REST automation API (any "/v1/..." request). Gets the
// path ("/v1/tap"), the raw query string (after '?', may be ""), the request body
// (POST, may be "") and its byte length `body_len` (for binary uploads — `body`
// may contain NULs). Returns a malloc'd response body (server frees it) and sets
// *status (e.g. 200, 400, 404). Return NULL to send an empty 200.
//   *out_ctype — set this to send a raw binary response: exactly *out_len bytes
//                with this Content-Type (e.g. "application/octet-stream"). If left
//                NULL, resp is treated as a NUL-terminated JSON string (strlen).
//   *out_len   — byte count for the binary response (used only when out_ctype set).
typedef char *(*rctl_rest_cb)(void *ctx, const char *path, const char *query,
                              const char *body, int body_len, int *status,
                              int *out_len, const char **out_ctype);
void rctl_http_set_rest(rctl_http_server *s, rctl_rest_cb cb, void *ctx);

// Register a callback fired when the live-stream subscriber count transitions
// between zero and non-zero: active=true when the FIRST /stream client connects,
// active=false when the LAST one leaves. Lets the device idle (stop capture +
// keep-awake) while nobody is watching, and wake on demand. Called off the mutex.
typedef void (*rctl_session_cb)(void *ctx, bool active);
void rctl_http_set_session(rctl_http_server *s, rctl_session_cb cb, void *ctx);

// True if at least one /stream client is currently subscribed.
bool rctl_http_has_clients(rctl_http_server *s);

// Sample egress backpressure for the bitrate-adaptation loop: *out_max_queue
// is the deepest subscriber send queue; *out_lagged counts subscribers that
// dropped video since the last sample (clearing their lagging flag). Either
// pointer may be NULL.
void rctl_http_egress_sample(rctl_http_server *s, int *out_max_queue, int *out_lagged);

void rctl_http_stop(rctl_http_server *s);

#ifdef __cplusplus
}
#endif
