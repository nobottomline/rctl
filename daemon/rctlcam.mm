// rctlcam — isolated camera-capture helper. Runs as its OWN process (spawned by
// rctld) so it can carry an NSCameraUsageDescription in its Info.plist (embedded
// via -sectcreate) — which SpringBoard lacks, and without which the camera-access
// privacy check SIGABRTs the caller. Capturing here also isolates any crash from
// SpringBoard. AVFoundation is driven via the ObjC runtime (no header import, to
// avoid the AVFoundation umbrella's camera/simd module-build failure).
//
//   rctlcam <position:1=back|2=front> <out.jpg>     exit 0 = ok, non-zero = reason
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        int position = argc > 1 ? atoi(argv[1]) : 1;
        NSString *outNS = [NSString stringWithUTF8String:(argc > 2 ? argv[2] : "/tmp/rctl_cam.jpg")];

        Class CDev = NSClassFromString(@"AVCaptureDevice");
        Class CInput = NSClassFromString(@"AVCaptureDeviceInput");
        Class CSession = NSClassFromString(@"AVCaptureSession");
        Class CStill = NSClassFromString(@"AVCaptureStillImageOutput");
        if (!CDev || !CInput || !CSession || !CStill) { fprintf(stderr, "no AVFoundation\n"); return 2; }

        long auth = ((long (*)(id, SEL, id))objc_msgSend)((id)CDev, NSSelectorFromString(@"authorizationStatusForMediaType:"), @"vide");
        fprintf(stderr, "auth=%ld pos=%d\n", auth, position);

        id chosen = nil;                                  // pick camera by position
        NSArray *devs = ((id (*)(id, SEL, id))objc_msgSend)((id)CDev, NSSelectorFromString(@"devicesWithMediaType:"), @"vide");
        for (id d in devs) {
            long p = ((long (*)(id, SEL))objc_msgSend)(d, NSSelectorFromString(@"position"));
            if (p == position) { chosen = d; break; }
        }
        if (!chosen) chosen = ((id (*)(id, SEL, id))objc_msgSend)((id)CDev, NSSelectorFromString(@"defaultDeviceWithMediaType:"), @"vide");
        if (!chosen) { fprintf(stderr, "no device\n"); return 3; }

        NSError *err = nil;
        id input = ((id (*)(id, SEL, id, NSError **))objc_msgSend)((id)CInput, NSSelectorFromString(@"deviceInputWithDevice:error:"), chosen, &err);
        if (!input) { fprintf(stderr, "input err: %s\n", err.localizedDescription.UTF8String); return 4; }

        id session = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)CSession, NSSelectorFromString(@"alloc")), NSSelectorFromString(@"init"));
        ((void (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"setSessionPreset:"), @"AVCaptureSessionPresetPhoto");
        if (!((BOOL (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"canAddInput:"), input)) { fprintf(stderr, "cant add input\n"); return 5; }
        ((void (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"addInput:"), input);

        id out = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)CStill, NSSelectorFromString(@"alloc")), NSSelectorFromString(@"init"));
        ((void (*)(id, SEL, id))objc_msgSend)(out, NSSelectorFromString(@"setOutputSettings:"), @{ @"AVVideoCodecKey": @"jpeg" });
        if (!((BOOL (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"canAddOutput:"), out)) { fprintf(stderr, "cant add output\n"); return 6; }
        ((void (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"addOutput:"), out);

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];   // why won't it run?
        [nc addObserverForName:@"AVCaptureSessionWasInterruptedNotification" object:session queue:nil usingBlock:^(NSNotification *n) {
            fprintf(stderr, "INTERRUPTED reason=%s\n", [[n.userInfo[@"AVCaptureSessionInterruptionReason"] description] UTF8String]);
        }];
        [nc addObserverForName:@"AVCaptureSessionRuntimeErrorNotification" object:session queue:nil usingBlock:^(NSNotification *n) {
            fprintf(stderr, "RUNTIME ERROR=%s\n", [[n.userInfo description] UTF8String]);
        }];
        ((void (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"startRunning"));
        __block int rc = 8;
        // Capture on the MAIN queue after a warm-up, with the main run loop spinning —
        // AVCaptureStillImageOutput needs the run loop serviced or it throws
        // "Inconsistent state". Stop the run loop when done (or on timeout).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id conn = ((id (*)(id, SEL, id))objc_msgSend)(out, NSSelectorFromString(@"connectionWithMediaType:"), @"vide");
            BOOL running = ((BOOL (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"isRunning"));
            BOOL active = conn ? ((BOOL (*)(id, SEL))objc_msgSend)(conn, NSSelectorFromString(@"isActive")) : NO;
            fprintf(stderr, "running=%d connActive=%d\n", running, active);
            if (!conn) { rc = 7; CFRunLoopStop(CFRunLoopGetMain()); return; }
            void (^done)(void *, NSError *) = ^(void *sbuf, NSError *e) {
                NSData *jpeg = sbuf ? ((id (*)(id, SEL, void *))objc_msgSend)((id)CStill, NSSelectorFromString(@"jpegStillImageNSDataRepresentation:"), sbuf) : nil;
                if (jpeg.length && [jpeg writeToFile:outNS atomically:YES]) rc = 0;
                else { fprintf(stderr, "no jpeg (len=%lu err=%s)\n", (unsigned long)jpeg.length, e.localizedDescription.UTF8String); rc = 9; }
                ((void (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"stopRunning"));
                CFRunLoopStop(CFRunLoopGetMain());
            };
            @try {
                ((void (*)(id, SEL, id, id))objc_msgSend)(out, NSSelectorFromString(@"captureStillImageAsynchronouslyFromConnection:completionHandler:"), conn, done);
            } @catch (NSException *ex) {
                fprintf(stderr, "capture threw: %s\n", ex.reason.UTF8String); rc = 10;
                ((void (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"stopRunning"));
                CFRunLoopStop(CFRunLoopGetMain());
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ fprintf(stderr, "timeout\n"); CFRunLoopStop(CFRunLoopGetMain()); });
        CFRunLoopRun();
        return rc;
    }
}
