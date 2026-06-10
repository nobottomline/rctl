// rctlsbcap — the thin SpringBoard agent. Captures + H.264-encodes the screen and
// injects touch/keyboard, but no longer hosts the network server: it streams
// encoded frames to the rctld daemon and receives input/config back over a local
// Unix socket. Keeping transport out of SpringBoard means a network bug can't
// respring the UI. Reconnects automatically if the daemon restarts.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <pthread.h>
#import <string.h>
#import <unistd.h>
#import <dlfcn.h>
#import "stream/CaptureSession.h"
#import "input/TouchInjector.h"
#import "ipc/Ipc.h"

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

static rctl_session     *gSession = NULL;
static dispatch_source_t gOrientTimer = NULL;
static id                gOrientObserver = nil;   // FBSOrientationObserver
static rctl_ipc         *gIpc = NULL;             // connection to rctld
static pthread_mutex_t   gIpcLock = PTHREAD_MUTEX_INITIALIZER;

// Encoded frames go to the daemon (dropped if it isn't connected yet).
static void net_sink(const uint8_t *data, size_t len, bool keyframe, void *ctx) {
    pthread_mutex_lock(&gIpcLock);
    if (gIpc) (void)rctl_ipc_send_prefixed(gIpc, RCTL_MSG_VIDEO, keyframe ? 1 : 0, data, (uint32_t)len);
    pthread_mutex_unlock(&gIpcLock);
}

static void send_orient(int o) {
    uint8_t b = (uint8_t)o;
    pthread_mutex_lock(&gIpcLock);
    if (gIpc) (void)rctl_ipc_send(gIpc, RCTL_MSG_ORIENT, &b, 1);
    pthread_mutex_unlock(&gIpcLock);
}

// Restart the capture/encode session with new settings (from the daemon's /config).
static void reconfigure(int fps, double scale, int bitrate) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSession) { rctl_session_stop(gSession); gSession = NULL; }
        gSession = rctl_session_start(fps, bitrate, scale, net_sink, NULL);
        NSLog(@"[rctl-sbcap] reconfigured fps=%d scale=%.2f br=%d", fps, scale, bitrate);
    });
}

// Connect to rctld, pump its commands, reconnect if it drops/restarts.
static void *ipc_manager(void *unused) {
    for (;;) {
        rctl_ipc *peer = rctl_ipc_connect(RCTL_IPC_SOCK_PATH);
        if (!peer) { usleep(500000); continue; }      // daemon not up yet
        NSLog(@"[rctl-sbcap] connected to rctld");
        pthread_mutex_lock(&gIpcLock); gIpc = peer; pthread_mutex_unlock(&gIpcLock);

        uint8_t type; uint8_t *buf; uint32_t len;
        while (rctl_ipc_recv(peer, &type, &buf, &len)) {
            if (type == RCTL_MSG_INPUT && len >= sizeof(rctl_ipc_input)) {
                rctl_ipc_input m; memcpy(&m, buf, sizeof m);
                rctl_input_touch(m.finger, m.x, m.y, m.phase);
            } else if (type == RCTL_MSG_KEY && len >= sizeof(rctl_ipc_key)) {
                rctl_ipc_key m; memcpy(&m, buf, sizeof m);
                if (m.page == 0xF0) { if (m.down) rctl_system_action(m.usage); }
                else rctl_input_key(m.page, m.usage, m.down);
            } else if (type == RCTL_MSG_CONFIG && len >= sizeof(rctl_ipc_config)) {
                rctl_ipc_config m; memcpy(&m, buf, sizeof m);
                reconfigure(m.fps, m.scale, m.bitrate);
            }
            free(buf);
        }

        NSLog(@"[rctl-sbcap] rctld disconnected");
        pthread_mutex_lock(&gIpcLock); if (gIpc == peer) gIpc = NULL; pthread_mutex_unlock(&gIpcLock);
        rctl_ipc_close(peer);
        usleep(300000);
    }
    return NULL;
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
            // Connect to the daemon (retrying) on a background thread.
            pthread_t t; pthread_create(&t, NULL, ipc_manager, NULL);

            // Default: native resolution, 30fps, 20 Mbps, High profile (screen-recording quality).
            gSession = rctl_session_start(30, 20000000, 1.0, net_sink, NULL);
            NSLog(@"[rctl-sbcap] capture session started");

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
                if (o >= 1 && o <= 4) send_orient(o);
            });
            dispatch_resume(gOrientTimer);
        });
    }
}
