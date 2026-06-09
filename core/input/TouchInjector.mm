// TouchInjector.mm — synthesize real touches on iOS 14 (method from
// Ryu0118/TouchSimulator-iOS14). Must run inside the foreground UIApplication
// process (SpringBoard for the home screen / system UI): build a hand+finger
// digitizer event, tag it with the key window's context id via
// BKSHIDEventSetDigitizerInfo, enqueue it into the app, and dispatch it.
// UIKit access ⇒ runs on the main thread. Private symbols via dlsym (stripped SDK).

#import "input/TouchInjector.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <dlfcn.h>
#import <unistd.h>
#import <stdio.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;

// Digitizer field IDs (base = kIOHIDEventTypeDigitizer(11) << 16 = 0xB0000).
enum {
    kFieldTiltX               = 0xB000D,
    kFieldTiltY               = 0xB000E,
    kFieldAltitude            = 0xB000F,
    kFieldMajorRadius         = 0xB0014,
    kFieldMinorRadius         = 0xB0015,
    kFieldIsDisplayIntegrated = 0xB0019,
};
enum { kEvRange = 0x1, kEvTouch = 0x2, kEvPosition = 0x4 };
static const uint32_t kHand = 3;                       // kIOHIDDigitizerTransducerTypeHand
static const uint64_t kSenderID = 0xDEFACEDBEEFFECE5ULL;
// A touch that begins within this fraction of any screen edge is treated as a
// possible system gesture (Control Center, app switcher, Notification Center).
static const double kEdgeFrac = 0.05;
static bool gEdgeGesture = false;  // latched at touch-down, held for the gesture

typedef IOHIDEventRef (*CreateDigitizer_f)(CFAllocatorRef, uint64_t, uint32_t type, uint32_t index,
    uint32_t identity, uint32_t eventMask, uint32_t buttonMask, IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat barrelPressure, int range, int touch, uint32_t options);
typedef IOHIDEventRef (*CreateFinger_f)(CFAllocatorRef, uint64_t, uint32_t index, uint32_t identity,
    uint32_t eventMask, IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
    int range, int touch, uint32_t options);
typedef void (*AppendEvent_f)(IOHIDEventRef, IOHIDEventRef, uint32_t);
typedef void (*SetInt_f)(IOHIDEventRef, uint32_t field, int value);
typedef void (*SetFloat_f)(IOHIDEventRef, uint32_t field, IOHIDFloat value);
typedef void (*SetSenderID_f)(IOHIDEventRef, uint64_t);
typedef IOHIDEventSystemClientRef (*ClientCreate_f)(CFAllocatorRef);
typedef void (*ClientDispatch_f)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef void (*BKSSetDigitizerInfo_f)(IOHIDEventRef, uint32_t contextID, uint8_t, uint8_t,
                                      CFStringRef, CFTimeInterval, float);
typedef IOHIDEventRef (*CreateKeyboard_f)(CFAllocatorRef, uint64_t, uint32_t usagePage,
                                          uint32_t usage, int down, uint32_t flags);

static CreateDigitizer_f _CreateDigitizer;
static CreateFinger_f    _CreateFinger;
static AppendEvent_f     _Append;
static SetInt_f          _SetInt;
static SetFloat_f        _SetFloat;
static SetSenderID_f     _SetSenderID;
static ClientCreate_f    _ClientCreate;
static ClientDispatch_f  _ClientDispatch;
static BKSSetDigitizerInfo_f _BKSSetDigitizerInfo;
static CreateKeyboard_f  _CreateKeyboard;
static IOHIDEventSystemClientRef gClient;
static bool gReady;

static void ilog(const char *s) {
    FILE *f = fopen("/tmp/rctl_input.log", "a");
    if (f) { fputs(s, f); fputc('\n', f); fclose(f); }
}

static void ensure_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        void *bks = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        _CreateDigitizer = (CreateDigitizer_f)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        _CreateFinger    = (CreateFinger_f)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        _Append          = (AppendEvent_f)dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        _SetInt          = (SetInt_f)dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
        _SetFloat        = (SetFloat_f)dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue");
        _SetSenderID     = (SetSenderID_f)dlsym(RTLD_DEFAULT, "IOHIDEventSetSenderID");
        _ClientCreate    = (ClientCreate_f)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        _ClientDispatch  = (ClientDispatch_f)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        _BKSSetDigitizerInfo = (BKSSetDigitizerInfo_f)dlsym(bks ? bks : RTLD_DEFAULT, "BKSHIDEventSetDigitizerInfo");
        _CreateKeyboard = (CreateKeyboard_f)dlsym(RTLD_DEFAULT, "IOHIDEventCreateKeyboardEvent");
        if (_ClientCreate) gClient = _ClientCreate(kCFAllocatorDefault);
        gReady = _CreateDigitizer && _CreateFinger && _Append && _SetInt && _ClientDispatch;
        char b[256];
        snprintf(b, sizeof(b), "[input] init14 ready=%d client=%p bks=%p enqueuePath=%s",
                 gReady, (void*)gClient, (void*)_BKSSetDigitizerInfo, "springboard");
        ilog(b);
    });
}

static UIWindow *key_window(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIWindow *w in app.windows) if (w.isKeyWindow) return w;
    return app.keyWindow;
}

// phase: 0=down, 1=move, 2=up. (x,y) normalized [0,1]. Runs on the main thread.
static void do_touch(int phase, double nx, double ny) {
    if (!gReady) return;
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *kw = key_window();
    if (!kw) return;

    // The digitizer interprets coordinates in the screen's FIXED (physical,
    // orientation-independent) space — NOT the rotated window space. The client
    // already sends fixed-space normalized coords, so just scale to fixed points.
    CGSize fsz = [UIScreen mainScreen].fixedCoordinateSpace.bounds.size;
    double x = nx * fsz.width;
    double y = ny * fsz.height;
    uint32_t ctx = ((uint32_t (*)(id, SEL))objc_msgSend)(kw, NSSelectorFromString(@"_contextId"));

    // Classify edge-origin gestures at touch-down and hold that for the whole
    // gesture. Only edge gestures get the systemGesture flag, so mid-screen
    // swipes (page flips, scrolling) keep behaving normally.
    if (phase == 0)
        gEdgeGesture = (nx < kEdgeFrac || nx > 1.0 - kEdgeFrac ||
                        ny < kEdgeFrac || ny > 1.0 - kEdgeFrac);

    static int dbg = 0;
    if (dbg++ < 8) {
        char b[320];
        snprintf(b, sizeof(b), "[input] phase=%d kw=%s ctx=%u fixed=%.0fx%.0f fixedPt=(%.0f,%.0f)",
                 phase, class_getName([kw class]), ctx, fsz.width, fsz.height, x, y);
        ilog(b);
    }

    uint64_t ts = mach_absolute_time();
    IOHIDEventRef parent = _CreateDigitizer(kCFAllocatorDefault, ts, kHand, 0, 0, kEvTouch, 0,
                                            0, 0, 0, 0, 0, 0, 1, 0);
    if (!parent) return;
    _SetInt(parent, kFieldIsDisplayIntegrated, 1);

    int isTouch = (phase == 2) ? 0 : 1;
    uint32_t mask = (phase == 1) ? kEvPosition : (kEvTouch | kEvRange);
    IOHIDEventRef child = _CreateFinger(kCFAllocatorDefault, ts, 1, 3, mask, x, y, 0, 0, 0,
                                        isTouch, isTouch, 0);
    if (child) {
        if (_SetFloat) { _SetFloat(child, kFieldMajorRadius, 0.04); _SetFloat(child, kFieldMinorRadius, 0.04); }
        _Append(parent, child, 0);
    }
    _SetInt(parent, kFieldTiltX, (int)kHand);
    _SetInt(parent, kFieldTiltY, 1);
    _SetInt(parent, kFieldAltitude, 1);

    if (_BKSSetDigitizerInfo) {
        // 3rd arg = systemGestureIsPossible. Set ONLY for edge-origin gestures so
        // the system's edge-swipe recognizers (Control Center from the top, app
        // switcher / dock from the bottom, Notification Center) consider them —
        // setting it for every touch hijacks normal scrolling/page swipes.
        _BKSSetDigitizerInfo(parent, ctx, gEdgeGesture ? 1 : 0, 0, NULL, 0, 0);
        ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(app, NSSelectorFromString(@"_enqueueHIDEvent:"), parent);
    }
    if (_SetSenderID) _SetSenderID(parent, kSenderID);
    if (gClient) _ClientDispatch(gClient, parent);
    CFRelease(parent);
}

void rctl_input_touch(int finger, double nx, double ny, int phase) {
    ensure_init();
    if (nx < 0) nx = 0; if (nx > 1) nx = 1;
    if (ny < 0) ny = 0; if (ny > 1) ny = 1;
    dispatch_async(dispatch_get_main_queue(), ^{ do_touch(phase, nx, ny); });
}

void rctl_input_tap(double nx, double ny) {
    rctl_input_touch(0, nx, ny, 0);
    usleep(40000);
    rctl_input_touch(0, nx, ny, 2);
}

int rctl_input_window_orientation(void) {
    UIWindow *kw = key_window();
    if (!kw) return 0;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *ws = kw.windowScene;
        if (ws) {
            long o = (long)ws.interfaceOrientation;
            if (o >= 1 && o <= 4) return (int)o;
        }
    }
    return 0;
}

static void post_key(int page, int usage, int down) {
    if (!_CreateKeyboard || !gClient) return;
    uint64_t ts = mach_absolute_time();
    IOHIDEventRef ev = _CreateKeyboard(kCFAllocatorDefault, ts, (uint32_t)page,
                                       (uint32_t)usage, down ? 1 : 0, 0);
    if (!ev) return;
    // Keyboard keys are delivered to the focused app via _enqueueHIDEvent;
    // Consumer buttons (Home/Power/Volume) are system events — dispatch only.
    if (page == 0x07) {
        UIApplication *app = [UIApplication sharedApplication];
        ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(app, NSSelectorFromString(@"_enqueueHIDEvent:"), ev);
    }
    if (_SetSenderID) _SetSenderID(ev, kSenderID);
    _ClientDispatch(gClient, ev);
    CFRelease(ev);
}

// down: 0=release, 1=press, 2=tap (press+release atomically, in order — used for
// regular keys so a lost/late release can't cause auto-repeat duplicates).
void rctl_input_key(int page, int usage, int down) {
    ensure_init();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (down == 2) { post_key(page, usage, 1); post_key(page, usage, 0); }
        else            post_key(page, usage, down);
    });
}
