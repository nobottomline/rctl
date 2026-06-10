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
// (Native screenshots are done client-side instead — SBScreenshotManager's
// save throws an async exception in its flash animation that aborts SpringBoard.)
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

// Launch an app by bundle id via SpringBoardServices. Call OFF the main thread
// (it's a synchronous client request to SpringBoard; on the main thread it
// self-deadlocks until a long timeout).
static void rctl_launch_app(NSString *bid) {
    if (!bid) return;
    static int (*SBSLaunch)(CFStringRef, Boolean) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        SBSLaunch = (int (*)(CFStringRef, Boolean))dlsym(h ? h : RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifier");
    });
    if (SBSLaunch) SBSLaunch((__bridge CFStringRef)bid, false);
}

// System alert (CFUserNotification) — shows over any app. Blocks a background
// thread until the user taps OK (so the notification ref stays alive).
typedef struct __CFUserNotification *CFUserNotificationRef;
extern CFUserNotificationRef CFUserNotificationCreate(CFAllocatorRef, CFTimeInterval, CFOptionFlags, SInt32 *, CFDictionaryRef);
extern SInt32 CFUserNotificationReceiveResponse(CFUserNotificationRef, CFTimeInterval, CFOptionFlags *);

static void rctl_show_alert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *d = @{ @"AlertHeader": title.length ? title : @"rctl",
                             @"AlertMessage": message ?: @"",
                             @"DefaultButtonTitle": @"OK" };
        SInt32 err = 0;
        CFUserNotificationRef n = CFUserNotificationCreate(NULL, 0, 0, &err, (__bridge CFDictionaryRef)d);
        if (n && !err) { CFOptionFlags resp; CFUserNotificationReceiveResponse(n, 0, &resp); }
        if (n) CFRelease(n);
    });
}

// Toast: a small pill that floats over everything for a moment.
static void rctl_show_toast(NSString *text, double seconds) {
    if (!text.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        UIFont *font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        CGSize ts = [text sizeWithAttributes:@{NSFontAttributeName: font}];
        CGFloat h = ts.height + 22, w = MIN(ts.width + 44, sw - 40);
        UIWindow *win = [[UIWindow alloc] initWithFrame:CGRectMake((sw - w) / 2, 58, w, h)];
        win.windowLevel = UIWindowLevelAlert + 1;
        win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
        win.layer.cornerRadius = h / 2;
        win.clipsToBounds = YES;
        win.userInteractionEnabled = NO;
        UILabel *lbl = [[UILabel alloc] initWithFrame:win.bounds];
        lbl.text = text; lbl.font = font; lbl.textColor = [UIColor whiteColor];
        lbl.textAlignment = NSTextAlignmentCenter;
        [win addSubview:lbl];
        win.hidden = NO;
        double dur = seconds > 0 ? seconds : 2.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dur * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ win.hidden = YES; });
    });
}

// Keep the device awake and unlocked for remote use: reset SpringBoard's idle
// timer (which drives auto-dim and auto-lock) and undim the display.
static void rctl_keep_awake(void) {
    UIApplication *app = [UIApplication sharedApplication];
    SEL withArg = NSSelectorFromString(@"resetIdleTimerAndUndim:");
    if ([app respondsToSelector:withArg]) { ((void (*)(id, SEL, BOOL))objc_msgSend)(app, withArg, YES); return; }
    SEL priv = NSSelectorFromString(@"_resetIdleTimerAndUndim:");
    if ([app respondsToSelector:priv]) { ((void (*)(id, SEL, BOOL))objc_msgSend)(app, priv, YES); return; }
    SEL noArg = NSSelectorFromString(@"resetIdleTimerAndUndim");
    if ([app respondsToSelector:noArg]) ((void (*)(id, SEL))objc_msgSend)(app, noArg);
}

static rctl_session     *gSession = NULL;
static dispatch_source_t gOrientTimer = NULL;
static dispatch_source_t gAwakeTimer = NULL;
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

// Reply to a daemon query: [4B BE reqid][UTF-8 payload].
static void send_reply(uint32_t reqid, NSString *result) {
    NSData *d = [(result ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    uint32_t blen = 4 + (uint32_t)d.length;
    uint8_t *buf = (uint8_t *)malloc(blen);
    buf[0] = reqid >> 24; buf[1] = reqid >> 16; buf[2] = reqid >> 8; buf[3] = (uint8_t)reqid;
    memcpy(buf + 4, d.bytes, d.length);
    pthread_mutex_lock(&gIpcLock);
    if (gIpc) (void)rctl_ipc_send(gIpc, RCTL_MSG_REPLY, buf, blen);
    pthread_mutex_unlock(&gIpcLock);
    free(buf);
}

static void rctl_set_clipboard(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{ [UIPasteboard generalPasteboard].string = text ?: @""; });
}

static NSString *rctl_get_clipboard(void) {  // call on the main thread
    return [UIPasteboard generalPasteboard].string ?: @"";
}

static NSString *rctl_device_info(void) {  // call on the main thread
    UIDevice *d = [UIDevice currentDevice];
    d.batteryMonitoringEnabled = YES;
    int pct = (int)(d.batteryLevel * 100 + 0.5);
    NSString *batt = pct >= 0 ? [NSString stringWithFormat:@"%d%%", pct] : @"?";
    return [NSString stringWithFormat:@"{\"name\":\"%@\",\"model\":\"%@\",\"ios\":\"%@\",\"battery\":\"%@\"}",
            d.name, d.model, d.systemVersion, batt];
}

// Open a URL via SpringBoardServices (and unlock). Off the main thread — it's a
// client->SpringBoard call that would self-deadlock on the main thread.
static void rctl_open_url(NSString *urlStr) {
    if (!urlStr.length) return;
    static void (*SBSOpenURL)(CFURLRef, Boolean) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        SBSOpenURL = (void (*)(CFURLRef, Boolean))dlsym(h ? h : RTLD_DEFAULT, "SBSOpenSensitiveURLAndUnlock");
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CFURLRef url = CFURLCreateWithString(NULL, (__bridge CFStringRef)urlStr, NULL);
        if (url && SBSOpenURL) SBSOpenURL(url, true);
        if (url) CFRelease(url);
    });
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
            } else if (type == RCTL_MSG_LAUNCH && len > 0) {
                NSString *bid = [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
                // MUST run off the main thread: SBSLaunch... is a client->SpringBoard
                // request, and calling it ON SpringBoard's main thread self-deadlocks
                // until a ~10s timeout (the UI freezes, then the app opens).
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                               ^{ rctl_launch_app(bid); });
            } else if (type == RCTL_MSG_ALERT && len > 0) {
                NSString *s = [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
                NSRange nl = [s rangeOfString:@"\n"];
                NSString *title = nl.location == NSNotFound ? s : [s substringToIndex:nl.location];
                NSString *msg   = nl.location == NSNotFound ? @"" : [s substringFromIndex:nl.location + 1];
                rctl_show_alert(title, msg);
            } else if (type == RCTL_MSG_TOAST && len > 0) {
                NSString *s = [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
                rctl_show_toast(s, 2.0);
            } else if (type == RCTL_MSG_SETCLIP) {
                rctl_set_clipboard([[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding] ?: @"");
            } else if (type == RCTL_MSG_OPENURL && len > 0) {
                rctl_open_url([[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding]);
            } else if (type == RCTL_MSG_QUERY && len >= 5) {
                uint32_t reqid = ((uint32_t)buf[0] << 24) | ((uint32_t)buf[1] << 16) | ((uint32_t)buf[2] << 8) | buf[3];
                uint8_t qtype = buf[4];
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *r = qtype == RCTL_Q_CLIPBOARD ? rctl_get_clipboard()
                                : qtype == RCTL_Q_DEVINFO   ? rctl_device_info() : @"";
                    send_reply(reqid, r);
                });
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
                // Use the FOREGROUND app's actual interface orientation (FrontBoard's
                // activeInterfaceOrientation). It is correct even for apps that force a
                // fixed orientation (e.g. a portrait-only game on a landscape device),
                // unlike the SpringBoard key window which tracks the device. Debounce:
                // only commit a change after it holds for 2 ticks, to drop the rare
                // transient reading seen while the device is being physically rotated.
                int raw = current_orientation();              // FBS activeInterfaceOrientation
                if (raw < 1 || raw > 4) raw = rctl_input_window_orientation();
                static int cand = 0, candN = 0, sent = 1;
                if (raw >= 1 && raw <= 4) {
                    if (raw == cand) candN++; else { cand = raw; candN = 1; }
                    if (candN >= 2) sent = cand;
                }
                send_orient(sent);
            });
            dispatch_resume(gOrientTimer);

            // Keep the device awake + unlocked for remote use (reset the idle timer).
            gAwakeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(gAwakeTimer, DISPATCH_TIME_NOW,
                                      (uint64_t)(10 * NSEC_PER_SEC), (uint64_t)NSEC_PER_SEC);
            dispatch_source_set_event_handler(gAwakeTimer, ^{ rctl_keep_awake(); });
            dispatch_resume(gAwakeTimer);
        });
    }
}
