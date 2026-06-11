#pragma once

#import <IOSurface/IOSurfaceRef.h>
#import <stddef.h>
#import <stdint.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Called for each encoded access unit, in Annex-B format (start codes), with
// SPS/PPS prepended on keyframes. `pts_us` is the capture presentation timestamp
// in microseconds, relative to the current capture session. Invoked on the
// encoder's internal queue.
typedef void (*rctl_nal_cb)(const uint8_t *data, size_t len, bool keyframe,
                            int64_t pts_us, void *ctx);

typedef struct rctl_encoder rctl_encoder;

// Encodes `srcW x srcH` BGRA IOSurface frames, GPU-downscaled to `dstW x dstH`
// (set dst == src to skip scaling). Output is Annex-B H.264.
rctl_encoder *rctl_encoder_create(int srcW, int srcH, int dstW, int dstH,
                                  int fps, int bitrate_bps, rctl_nal_cb cb, void *ctx);
void rctl_encoder_encode(rctl_encoder *e, IOSurfaceRef surface, int64_t pts_us);
void rctl_encoder_destroy(rctl_encoder *e);

#ifdef __cplusplus
}
#endif
