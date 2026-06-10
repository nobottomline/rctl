// rctlmsd — injected into mediaserverd. Proven injection point for defeating the
// camera foreground gate. RE findings so far:
//   * FigCaptureClientSessionMonitor owns the ongoing foreground/background state
//     (-applicationState; enum 0=Undefined,1=Backgrounded,2=Foregrounded), but it
//     is created only AFTER a session is running — forcing it does NOT help us.
//   * Our capture (rctlcam daemon AND SpringBoard off the home screen) is rejected
//     at SESSION START, before any monitor exists: mediaserverd only lets the
//     FRONTMOST app capture. The start-time gate (BWFigCaptureSession /
//     FigCaptureSource _setInterrupted:withReason:) is the next thing to RE+hook.
// Currently NEUTRAL (no behaviour change) so the media subsystem stays stable
// until that gate is found.
#import <Foundation/Foundation.h>

%ctor {
    @try {
        if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"mediaserverd"]) return;
        [@"rctlmsd loaded (neutral)\n" writeToFile:@"/tmp/msd_log.txt" atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) {}
}
