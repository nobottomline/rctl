#pragma once

#import "encode/H264Encoder.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rctl_session rctl_session;

// Start a capture+encode session: a timer renders the display at `fps` and feeds
// each frame to the H.264 encoder; encoded access units are delivered via `cb`.
rctl_session *rctl_session_start(int fps, int bitrate_bps, double scale, rctl_nal_cb cb, void *ctx);
void rctl_session_stop(rctl_session *s);

// Live encode tuning while a session runs (forwarded to the encoder).
// Must not be called after rctl_session_stop.
void rctl_session_set_bitrate(rctl_session *s, int bitrate_bps);
void rctl_session_request_keyframe(rctl_session *s);

#ifdef __cplusplus
}
#endif
