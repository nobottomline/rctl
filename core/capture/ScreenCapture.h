#pragma once

#import <IOSurface/IOSurfaceRef.h>
#import <stddef.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Create a global BGRA IOSurface sized to the main display times `scale`
// (1.0 = native). Caller owns it (CFRelease). Writes pixel dims to outW/outH.
IOSurfaceRef rctl_capture_create_surface(double scale, size_t *outW, size_t *outH);

// Render the current display content into `dst` (a surface from create_surface).
// Only produces pixels when called from inside the render-server process (SpringBoard).
void rctl_capture_render(IOSurfaceRef dst);

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
