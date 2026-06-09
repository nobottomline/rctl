#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Inject a touch. phase: 0 = down/begin, 1 = move, 2 = up/end.
// (nx, ny) are normalized [0,1] in the framebuffer (panel-native) coordinate space.
// `finger` distinguishes simultaneous touches (0..15).
void rctl_input_touch(int finger, double nx, double ny, int phase);

// Convenience: a quick tap (down then up) at a normalized point.
void rctl_input_tap(double nx, double ny);

// The key window's interface orientation (UIInterfaceOrientation 1..4), or 0.
// More reliable than FBSOrientationObserver and consistent with touch mapping.
int rctl_input_window_orientation(void);

#ifdef __cplusplus
}
#endif
