#pragma once

#import <IOSurface/IOSurfaceRef.h>
#import <stddef.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rctl_capture rctl_capture;

// Owns native render and, only for rotated panels, canonical BGRA surfaces.
// Output dimensions and pixels always use UIKit's fixed portrait coordinates.
rctl_capture *rctl_capture_create(size_t *outW, size_t *outH);
void rctl_capture_destroy(rctl_capture *capture);

// Caller serializes render/snapshot/destroy. Returns a borrowed surface, or NULL
// on failure. Only produces pixels inside SpringBoard's render-server context.
IOSurfaceRef rctl_capture_render(rctl_capture *capture);

// Undim / wake the display so the render server composites a frame.
void rctl_capture_wake_display(void);

// Acquire/release the display idle-sleep assertion. Must follow the remote media
// lifecycle so an ended session does not keep the device awake.
void rctl_capture_set_keep_awake(bool awake);

// Lightweight idle-timer reset (no delay) — call periodically to keep the screen on.
void rctl_capture_undim(void);

// Convenience: capture a single frame to a PNG file. Returns 0 on success.
int rctl_capture_one_png(const char *path);

// Encode an already-rendered BGRA IOSurface to a lossless PNG file (dimensions
// read from the surface). Shared by the one-shot grab and the live session's
// snapshot. Returns 0 on success.
int rctl_surface_to_png(IOSurfaceRef surface, const char *path);

#ifdef __cplusplus
}
#endif
