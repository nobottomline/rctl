// rctlsbcap — runs the capture+encode session inside SpringBoard and serves the
// live H.264 stream over HTTP (MVP: server co-located here; will move to the daemon).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "stream/CaptureSession.h"
#import "net/HttpStreamServer.h"
#import "input/TouchInjector.h"

// Edge system gestures (Control Center, Cover Sheet) can't be synthesized into
// the right window via HID, so trigger them directly through SpringBoard's
// presentation controllers. Selectors verified on iOS 14.4 by runtime probe.
// code: 1=Control Center, 2=Cover Sheet / Notification Center. Each toggles.
static void rctl_system_action(int code) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (code == 1) {
            id cc = ((id (*)(id, SEL))objc_msgSend)((id)NSClassFromString(@"SBControlCenterController"),
                                                    NSSelectorFromString(@"sharedInstance"));
            if (!cc) return;
            BOOL vis = ((BOOL (*)(id, SEL))objc_msgSend)(cc, NSSelectorFromString(@"isVisible"));
            ((void (*)(id, SEL, BOOL))objc_msgSend)(cc,
                NSSelectorFromString(vis ? @"dismissAnimated:" : @"presentAnimated:"), YES);
        } else if (code == 2) {
            id cs = ((id (*)(id, SEL))objc_msgSend)((id)NSClassFromString(@"SBCoverSheetPresentationManager"),
                                                    NSSelectorFromString(@"sharedInstance"));
            if (!cs) return;
            BOOL vis = ((BOOL (*)(id, SEL))objc_msgSend)(cs, NSSelectorFromString(@"isVisible"));
            ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(cs,
                NSSelectorFromString(@"setCoverSheetPresented:animated:withCompletion:"), !vis, YES, nil);
        }
    });
}

static rctl_http_server *gServer = NULL;
static rctl_session *gSession = NULL;
static dispatch_source_t gOrientTimer = NULL;
static id gOrientObserver = nil; // FBSOrientationObserver

static void net_sink(const uint8_t *data, size_t len, bool keyframe, void *ctx) {
    rctl_http_push_au((rctl_http_server *)ctx, data, len, keyframe);
}

// Restart the capture/encode session with new settings (from GET /config).
static void reconfigure(void *ctx, int fps, double scale, int bitrate) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSession) { rctl_session_stop(gSession); gSession = NULL; }
        rctl_http_signal_reset(gServer);
        gSession = rctl_session_start(fps, bitrate, scale, net_sink, gServer);
        NSLog(@"[rctl-sbcap] reconfigured fps=%d scale=%.2f br=%d", fps, scale, bitrate);
    });
}

// Inject client input directly here in SpringBoard (iOS 14 method enqueues into
// the foreground UIApplication = SpringBoard for the home screen / system UI).
static void input_handler(void *ctx, int phase, int finger, double nx, double ny) {
    rctl_input_touch(finger, nx, ny, phase);
}

static void key_handler(void *ctx, int page, int usage, int down) {
    // Sentinel page 0xF0 = SpringBoard presentation actions (fire on key-down).
    if (page == 0xF0) { if (down) rctl_system_action(usage); return; }
    rctl_input_key(page, usage, down);
}

// Authoritative interface orientation from FrontBoard (matches the framebuffer).
static int current_orientation(void) {
    if (!gOrientObserver) return 0;
    long o = ((long (*)(id, SEL))objc_msgSend)(gOrientObserver,
                NSSelectorFromString(@"activeInterfaceOrientation"));
    return (int)o;
}

%ctor {
    @autoreleasepool {
        if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) return;
        NSLog(@"[rctl-sbcap] loaded in SpringBoard");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            gServer = rctl_http_start(8080);
            if (!gServer) { NSLog(@"[rctl-sbcap] server failed to start"); return; }
            rctl_http_set_reconfigure(gServer, reconfigure, NULL);
            rctl_http_set_input(gServer, input_handler, NULL);
            rctl_http_set_key(gServer, key_handler, NULL);

            // Default: native resolution, 30fps, 20 Mbps, High profile (screen-recording quality).
            gSession = rctl_session_start(30, 20000000, 1.0, net_sink, gServer);
            NSLog(@"[rctl-sbcap] streaming on :8080");

            dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
            Class cls = NSClassFromString(@"FBSOrientationObserver");
            if (cls) gOrientObserver = ((id (*)(id, SEL))objc_msgSend)((id)cls, NSSelectorFromString(@"alloc"));
            if (gOrientObserver) gOrientObserver = ((id (*)(id, SEL))objc_msgSend)(gOrientObserver, NSSelectorFromString(@"init"));

            gOrientTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(gOrientTimer, DISPATCH_TIME_NOW,
                                      (uint64_t)(250 * NSEC_PER_MSEC), (uint64_t)(50 * NSEC_PER_MSEC));
            dispatch_source_set_event_handler(gOrientTimer, ^{
                int o = rctl_input_window_orientation();      // reliable: from the key window
                if (o < 1 || o > 4) o = current_orientation(); // fallback to FBS
                if (o >= 1 && o <= 4) rctl_http_set_orientation(gServer, o);
            });
            dispatch_resume(gOrientTimer);
        });
    }
}
