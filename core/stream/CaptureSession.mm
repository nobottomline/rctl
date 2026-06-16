// CaptureSession.mm — drives capture + encode on a timer.

#import "stream/CaptureSession.h"
#import "capture/ScreenCapture.h"
#import <Foundation/Foundation.h>
#import <stdio.h>
#import <stdlib.h>
#import <time.h>

struct rctl_session {
    IOSurfaceRef surface;
    rctl_encoder *enc;
    dispatch_queue_t queue;
    dispatch_source_t timer;
    int64_t startUs;
    int64_t frames;
};

static int64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

rctl_session *rctl_session_start(int fps, int bitrate, double scale, rctl_nal_cb cb, void *ctx) {
    if (fps <= 0) fps = 30;
    if (scale <= 0 || scale > 1.0) scale = 1.0;
    rctl_capture_wake_display();
    rctl_capture_keep_awake(); // keep the display on for the whole session

    // Capture full screen at native resolution; the encoder GPU-downscales.
    size_t w = 0, h = 0;
    IOSurfaceRef surf = rctl_capture_create_surface(1.0, &w, &h);
    if (!surf) { fprintf(stderr, "[session] no surface\n"); return NULL; }

    int dstW = (int)(((size_t)(w * scale)) & ~1UL);
    int dstH = (int)(((size_t)(h * scale)) & ~1UL);
    rctl_encoder *enc = rctl_encoder_create((int)w, (int)h, dstW, dstH, fps, bitrate, cb, ctx);
    if (!enc) { CFRelease(surf); return NULL; }

    rctl_session *s = (rctl_session *)calloc(1, sizeof(rctl_session));
    s->surface = surf;
    s->enc = enc;
    s->startUs = now_us();
    s->queue = dispatch_queue_create("com.greatlove.rctl.capture", DISPATCH_QUEUE_SERIAL);
    s->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, s->queue);

    uint64_t interval = NSEC_PER_SEC / (uint64_t)fps;
    dispatch_source_set_timer(s->timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval, interval / 10);
    dispatch_source_set_event_handler(s->timer, ^{
        rctl_capture_render(s->surface);
        rctl_encoder_encode(s->enc, s->surface, now_us() - s->startUs);
        if ((s->frames % 450) == 0) rctl_capture_undim(); // keep the screen on (~every 15s)
        s->frames++;
    });
    dispatch_resume(s->timer);

    fprintf(stderr, "[session] started %zux%zu @%dfps\n", w, h, fps);
    return s;
}

void rctl_session_set_bitrate(rctl_session *s, int bitrate_bps) {
    if (s && s->enc) rctl_encoder_set_bitrate(s->enc, bitrate_bps);
}

void rctl_session_request_keyframe(rctl_session *s) {
    if (s && s->enc) rctl_encoder_request_keyframe(s->enc);
}

void rctl_session_stop(rctl_session *s) {
    if (!s) return;
    if (s->timer) {
        dispatch_source_cancel(s->timer);
        dispatch_sync(s->queue, ^{}); // drain any in-flight encode before destroying VT/IOSurface
        s->timer = NULL;
    }
    if (s->enc) { rctl_encoder_destroy(s->enc); s->enc = NULL; }
    if (s->surface) { CFRelease(s->surface); s->surface = NULL; }
    fprintf(stderr, "[session] stopped after %lld frames\n", (long long)s->frames);
    free(s);
}
