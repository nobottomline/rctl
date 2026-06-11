// rctlaudioprobe — diagnostic-only mediaserverd audio surface probe.
//
// This file must stay behavior-neutral: no hooks, no swizzling, no render-path
// modification. It logs class/symbol availability when explicitly loaded into
// mediaserverd for reverse engineering.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>
#import <time.h>

static FILE *probe_log_open(void) {
    return fopen("/tmp/rctl-audioprobe.log", "a");
}

static void probe_log(FILE *f, NSString *line) {
    if (!f || !line) return;
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (d.length) fwrite(d.bytes, 1, d.length, f);
    fwrite("\n", 1, 1, f);
}

static void probe_class(FILE *f, const char *name) {
    Class cls = objc_getClass(name);
    probe_log(f, [NSString stringWithFormat:@"class %-48s %@", name, cls ? @"YES" : @"no"]);
}

static void probe_symbol(FILE *f, const char *name) {
    void *sym = dlsym(RTLD_DEFAULT, name);
    probe_log(f, [NSString stringWithFormat:@"symbol %-47s %p", name, sym]);
}

%ctor {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"?";
        if (![proc isEqualToString:@"mediaserverd"]) return;

        FILE *f = probe_log_open();
        if (!f) return;

        time_t now = time(NULL);
        probe_log(f, @"--- rctlaudioprobe loaded ---");
        probe_log(f, [NSString stringWithFormat:@"time %ld pid %d process %@", (long)now, getpid(), proc]);

        const char *classes[] = {
            "Core_Audio_Daemon",
            "AVAudioSession",
            "AVAudioPlayer",
            "AVAudioRecorder",
            "AVCaptureAudioDataOutput",
            "AVCaptureFigAudioDevice",
            "BWAudioSourceNode",
            "FigAudioCaptureConnectionConfiguration",
            "FigCaptureAudioDataSinkConfiguration",
            "FigCaptureAudioDataSinkPipeline",
            "FigCaptureAudioFileSinkConfiguration",
            "FigCaptureAudioFileSinkPipeline",
            NULL
        };
        for (int i = 0; classes[i]; i++) probe_class(f, classes[i]);

        const char *symbols[] = {
            "AudioComponentFindNext",
            "AudioComponentInstanceNew",
            "AudioOutputUnitStart",
            "AudioOutputUnitStop",
            "AudioUnitGetProperty",
            "AudioUnitSetProperty",
            "AudioUnitRender",
            "AudioQueueNewOutput",
            "AudioQueueStart",
            "AudioQueueEnqueueBuffer",
            "CMSessionCreate",
            "FigAudioQueueCreate",
            NULL
        };
        for (int i = 0; symbols[i]; i++) probe_symbol(f, symbols[i]);

        probe_log(f, @"--- rctlaudioprobe done ---");
        fclose(f);
    }
}
