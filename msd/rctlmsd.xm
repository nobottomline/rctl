// rctlmsd — injected into mediaserverd. Diagnostic: trace the capture-client
// lifecycle to find exactly where our (non-frontmost) client is rejected. Read-only
// (logs + %orig), so the media subsystem behaviour is unchanged.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void L(NSString *s) {
    @try {
        NSData *d = [[s stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *f = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/msd_log.txt"];
        if (!f) { [[s stringByAppendingString:@"\n"] writeToFile:@"/tmp/msd_log.txt" atomically:NO encoding:NSUTF8StringEncoding error:nil]; return; }
        [f seekToEndOfFile]; [f writeData:d]; [f closeFile];
    } @catch (id e) {}
}

%hook FigCaptureClientSessionMonitor
- (id)initWithClientAuditToken:(id)t forThirdPartyTorch:(BOOL)tp applicationAndLayoutStateHandler:(id)a interruptionHandler:(id)b {
    L(@"MONITOR created (initWithClientAuditToken)"); return %orig;
}
- (BOOL)_isApplicationStateMonitoringRequiredForClient {
    BOOL r = %orig; L([NSString stringWithFormat:@"MONITOR _isAppStateMonitoringRequired=%d", r]); return r;
}
- (long long)applicationState {
    long long r = %orig; L([NSString stringWithFormat:@"MONITOR applicationState=%lld", r]); return r;
}
- (id)applicationID {
    id r = %orig; L([NSString stringWithFormat:@"MONITOR applicationID=%@", r]); return r;
}
%end

%hook BWFigCaptureSession
- (id)initWithFigCaptureSession:(id)s { L(@"BWSESSION created"); return %orig; }
- (void)layoutMonitor:(id)m didUpdateLayoutWithForegroundApps:(id)fg obscuredApps:(id)ob transitioningApps:(id)tr pipApps:(id)pip {
    L([NSString stringWithFormat:@"BWSESSION layout fg=%@ obscured=%@", fg, ob]); %orig;
}
%end

%ctor {
    @try {
        if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"mediaserverd"]) return;
        L(@"--- rctlmsd diag loaded ---");
    } @catch (id e) {}
}
