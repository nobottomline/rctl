// rctld — root daemon, supervised by launchd (RunAtLoad + KeepAlive).
// Will host the transport (WebSocket/REST/WebRTC) and relay between browsers and
// the SpringBoard agent over a local socket. This first cut only proves the
// launchd lifecycle (starts at boot, restarts on crash) before logic moves in.

#import <Foundation/Foundation.h>
#import <stdio.h>
#import <time.h>
#import <unistd.h>

static void dlog(const char *msg) {
    FILE *f = fopen("/tmp/rctld.log", "a");
    if (f) { fprintf(f, "[%ld pid=%d] %s\n", (long)time(NULL), getpid(), msg); fclose(f); }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        dlog("rctld started");

        // Heartbeat so we can confirm it stays alive (and KeepAlive respawns it).
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                         dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, (uint64_t)5 * NSEC_PER_SEC, NSEC_PER_SEC);
        __block int n = 0;
        dispatch_source_set_event_handler(timer, ^{
            char b[64]; snprintf(b, sizeof b, "heartbeat %d", ++n); dlog(b);
        });
        dispatch_resume(timer);

        dispatch_main();
    }
    return 0;
}
