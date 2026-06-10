// TouchInjector.mm — synthesize touches on iOS 14 and deliver them to whatever
// app is frontmost (games and third-party apps, not just SpringBoard).
//
// Method: build a digitizer (hand+finger) IOHIDEvent and dispatch it straight
// into the HID event system tagged with the REAL hardware digitizer's senderID.
// Because the event carries the genuine sensor's id, the system routes it through
// the normal touch-delivery path to the foreground application. The senderID is
// acquired by enumerating HID services (no physical touch needed); as a fallback
// it is captured from the first real touch via an event callback.
//
// Until a senderID is known we fall back to the SpringBoard-only path (enqueue
// into the foreground UIApplication), so the home screen still works immediately.
// Runs on the main thread (UIKit + a live run loop for the callback). Private
// symbols are resolved via dlsym (the stripped SDK ships no IOKit headers).

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
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef double IOHIDFloat;

// Digitizer field IDs (base = kIOHIDEventTypeDigitizer(11) << 16 = 0xB0000).
enum {
    kFieldChildCount          = 0xB0007,
    kFieldButtonMask          = 0xB0008,
    kFieldEventMaskField      = 0xB0009,
    kFieldTiltX               = 0xB000D,
    kFieldTiltY               = 0xB000E,
    kFieldAltitude            = 0xB000F,
    kFieldMajorRadius         = 0xB0014,
    kFieldMinorRadius         = 0xB0015,
    kFieldIsDisplayIntegrated = 0xB0019,
};
enum { kEvRange = 0x1, kEvTouch = 0x2, kEvPosition = 0x4 };
enum { kHIDEventTypeDigitizer = 11 };
static const uint32_t kHand = 3;                       // kIOHIDDigitizerTransducerTypeHand
static const uint64_t kFallbackSenderID = 0xDEFACEDBEEFFECE5ULL;

// HID digitizer usage (page 0x0D): TouchScreen=0x04, Pen=0x02, TouchPad=0x05.
enum { kPageDigitizer = 0x0D, kUsageTouchScreen = 0x04, kUsageDigitizer = 0x02 };

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
typedef uint64_t (*GetSenderID_f)(IOHIDEventRef);
typedef uint32_t (*GetEventType_f)(IOHIDEventRef);
typedef IOHIDEventSystemClientRef (*ClientCreate_f)(CFAllocatorRef);
typedef void (*ClientDispatch_f)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef CFArrayRef (*CopyServices_f)(IOHIDEventSystemClientRef);
typedef int (*ServiceConforms_f)(IOHIDServiceClientRef, uint32_t page, uint32_t usage);
typedef uint64_t (*ServiceRegistryID_f)(IOHIDServiceClientRef);
typedef void (*RegisterCallback_f)(IOHIDEventSystemClientRef, void *callback, void *target, void *refcon);
typedef void (*ScheduleRunLoop_f)(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef mode);
typedef void (*BKSSetDigitizerInfo_f)(IOHIDEventRef, uint32_t contextID, uint8_t, uint8_t,
                                      CFStringRef, CFTimeInterval, float);
typedef IOHIDEventRef (*CreateKeyboard_f)(CFAllocatorRef, uint64_t, uint32_t usagePage,
                                          uint32_t usage, int down, uint32_t flags);

static CreateDigitizer_f   _CreateDigitizer;
static CreateFinger_f      _CreateFinger;
static AppendEvent_f       _Append;
static SetInt_f            _SetInt;
static SetFloat_f          _SetFloat;
static SetSenderID_f       _SetSenderID;
static GetSenderID_f       _GetSenderID;
static GetEventType_f      _GetEventType;
static ClientCreate_f      _ClientCreate;
static ClientDispatch_f    _ClientDispatch;
static CopyServices_f      _CopyServices;
static ServiceConforms_f   _ServiceConforms;
static ServiceRegistryID_f _ServiceRegistryID;
static RegisterCallback_f  _RegisterCallback;
static ScheduleRunLoop_f   _ScheduleRunLoop;
static BKSSetDigitizerInfo_f _BKSSetDigitizerInfo;
static CreateKeyboard_f    _CreateKeyboard;

static IOHIDEventSystemClientRef gClient;        // for dispatching synthetic events
static IOHIDEventSystemClientRef gSenderClient;  // for capturing the real senderID
static uint64_t gSenderID = 0;                   // real digitizer id (0 = not yet known)
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
        _CreateDigitizer   = (CreateDigitizer_f)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        _CreateFinger      = (CreateFinger_f)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        _Append            = (AppendEvent_f)dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        _SetInt            = (SetInt_f)dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
        _SetFloat          = (SetFloat_f)dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue");
        _SetSenderID       = (SetSenderID_f)dlsym(RTLD_DEFAULT, "IOHIDEventSetSenderID");
        _GetSenderID       = (GetSenderID_f)dlsym(RTLD_DEFAULT, "IOHIDEventGetSenderID");
        _GetEventType      = (GetEventType_f)dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
        _ClientCreate      = (ClientCreate_f)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        _ClientDispatch    = (ClientDispatch_f)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        _CopyServices      = (CopyServices_f)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
        _ServiceConforms   = (ServiceConforms_f)dlsym(RTLD_DEFAULT, "IOHIDServiceClientConformsTo");
        _ServiceRegistryID = (ServiceRegistryID_f)dlsym(RTLD_DEFAULT, "IOHIDServiceClientGetRegistryID");
        _RegisterCallback  = (RegisterCallback_f)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientRegisterEventCallback");
        _ScheduleRunLoop   = (ScheduleRunLoop_f)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientScheduleWithRunLoop");
        _BKSSetDigitizerInfo = (BKSSetDigitizerInfo_f)dlsym(bks ? bks : RTLD_DEFAULT, "BKSHIDEventSetDigitizerInfo");
        _CreateKeyboard    = (CreateKeyboard_f)dlsym(RTLD_DEFAULT, "IOHIDEventCreateKeyboardEvent");
        if (_ClientCreate) gClient = _ClientCreate(kCFAllocatorDefault);
        gReady = _CreateDigitizer && _CreateFinger && _Append && _SetInt && _ClientDispatch;
        char b[256];
        snprintf(b, sizeof(b), "[input] init ready=%d client=%p copyServices=%p registryID=%p",
                 gReady, (void*)gClient, (void*)_CopyServices, (void*)_ServiceRegistryID);
        ilog(b);
    });
}

// Capture the real senderID from a genuine hardware touch. Critically, ignore
// our OWN injected events (they carry kFallbackSenderID and are echoed back to
// this listener) — otherwise we'd capture the fake id and poison every touch.
static void senderid_callback(void *target, void *refcon, void *service, IOHIDEventRef event) {
    if (gSenderID != 0 || !_GetSenderID) return;
    if (_GetEventType && _GetEventType(event) != kHIDEventTypeDigitizer) return;
    uint64_t sid = _GetSenderID(event);
    if (sid && sid != kFallbackSenderID) {
        gSenderID = sid;
        char b[80]; snprintf(b, sizeof b, "[input] real senderID captured: 0x%llx", sid); ilog(b);
    }
}

// Acquire the genuine digitizer senderID by capturing it from the next real
// touch (the value carried by hardware digitizer events). Runs on the main
// thread (the callback needs a live run loop). Until it is known, do_touch uses
// the SpringBoard fallback so the home screen keeps working immediately.
static void ensure_senderid(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (_RegisterCallback && _ScheduleRunLoop && _ClientCreate) {
            gSenderClient = _ClientCreate(kCFAllocatorDefault);
            if (gSenderClient) {
                _ScheduleRunLoop(gSenderClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
                _RegisterCallback(gSenderClient, (void *)senderid_callback, NULL, NULL);
            }
        }
        ilog("[input] senderID: capturing from first real touch (SpringBoard fallback until then)");
    });
}

static UIWindow *key_window(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIWindow *w in app.windows) if (w.isKeyWindow) return w;
    return app.keyWindow;
}

// System-wide path: dispatch a digitizer event with the real senderID so it
// reaches the foreground app. (x,y) normalized [0,1] in the screen's fixed space.
static void do_touch_system(int finger, int phase, double nx, double ny) {
    uint64_t ts = mach_absolute_time();
    IOHIDEventRef parent = _CreateDigitizer(kCFAllocatorDefault, ts, kHand, 99, 1, 0, 0,
                                            0, 0, 0, 0, 0, 0, 0, 0);
    if (!parent) return;
    _SetInt(parent, kFieldIsDisplayIntegrated, 1);
    _SetInt(parent, 0x4, 1);   // digitizer event flag

    uint32_t mask = (phase == 1) ? kEvPosition : (phase == 2 ? kEvTouch : (kEvRange | kEvTouch));
    int range = (phase == 2) ? 0 : 1;
    int touch = (phase == 2) ? 0 : 1;
    IOHIDEventRef child = _CreateFinger(kCFAllocatorDefault, ts, (uint32_t)finger, 3, mask,
                                        nx, ny, 0, 0, 0, range, touch, 0);
    if (child) {
        if (_SetFloat) { _SetFloat(child, kFieldMajorRadius, 0.04); _SetFloat(child, kFieldMinorRadius, 0.04); }
        _Append(parent, child, 0);
    }
    _SetInt(parent, kFieldChildCount, 0x23);
    _SetInt(parent, kFieldButtonMask, 1);
    _SetInt(parent, kFieldEventMaskField, 1);

    if (_SetSenderID) _SetSenderID(parent, gSenderID);
    _ClientDispatch(gClient, parent);
    CFRelease(parent);
}

// Fallback path (used only until a senderID is known): enqueue into the
// foreground UIApplication. Controls SpringBoard UI only. (x,y) normalized.
static void do_touch_springboard(int phase, double nx, double ny) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *kw = key_window();
    if (!kw) return;
    CGSize fsz = [UIScreen mainScreen].fixedCoordinateSpace.bounds.size;
    double x = nx * fsz.width, y = ny * fsz.height;
    uint32_t ctx = ((uint32_t (*)(id, SEL))objc_msgSend)(kw, NSSelectorFromString(@"_contextId"));

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
        _BKSSetDigitizerInfo(parent, ctx, 0, 0, NULL, 0, 0);
        ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(app, NSSelectorFromString(@"_enqueueHIDEvent:"), parent);
    }
    if (_SetSenderID) _SetSenderID(parent, kFallbackSenderID);
    if (gClient) _ClientDispatch(gClient, parent);
    CFRelease(parent);
}

// phase: 0=down, 1=move, 2=up. (x,y) normalized [0,1]. Runs on the main thread.
static void do_touch(int finger, int phase, double nx, double ny) {
    if (!gReady) return;
    ensure_senderid();

    static int dbg = 0;
    if (dbg++ < 8) {
        char b[160];
        snprintf(b, sizeof b, "[input] touch finger=%d phase=%d n=(%.3f,%.3f) sender=0x%llx path=%s",
                 finger, phase, nx, ny, gSenderID, gSenderID ? "system" : "springboard");
        ilog(b);
    }

    if (gSenderID) do_touch_system(finger, phase, nx, ny);
    else           do_touch_springboard(phase, nx, ny);
}

void rctl_input_touch(int finger, double nx, double ny, int phase) {
    ensure_init();
    if (nx < 0) nx = 0; if (nx > 1) nx = 1;
    if (ny < 0) ny = 0; if (ny > 1) ny = 1;
    dispatch_async(dispatch_get_main_queue(), ^{ do_touch(finger, phase, nx, ny); });
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
    if (_SetSenderID) _SetSenderID(ev, kFallbackSenderID);
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
