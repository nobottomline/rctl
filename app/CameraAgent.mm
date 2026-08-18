#import "CameraAgent.h"
#import "encode/H264Encoder.h"
#import "net/CameraProtocol.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <arpa/inet.h>
#include <dlfcn.h>
#include <netinet/in.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <unistd.h>

static dispatch_queue_t gCameraQueue;
static dispatch_queue_t gCameraNetworkQueue;
static dispatch_source_t gCameraStateTimer;
static id gCameraSession;
static id gCameraOutput;
static id gCameraDelegate;
static rctl_encoder *gCameraEncoder;
static int gCameraWidth;
static int gCameraHeight;
static int gCameraFPS = 10;
static int gCameraBitrate = 1500000;
static int gCameraPosition = 1;
static uint64_t gCameraGeneration;
static int64_t gCameraLastEncodedPTS;
static _Atomic bool gCameraRunning;
static _Atomic bool gCameraSyncInFlight;
static int gCameraSocket = -1;
static uint64_t gCameraSocketGeneration;
static _Atomic int gCameraPendingFrames;
static rctl_camera_tcc_callback gCameraTCCCallback;

static void camera_set_tcc_active(BOOL active) {
    if (gCameraTCCCallback) gCameraTCCCallback(active);
}

static uint64_t camera_hton64(uint64_t value) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return ((uint64_t)htonl((uint32_t)(value & 0xffffffffULL)) << 32) |
           htonl((uint32_t)(value >> 32));
#else
    return value;
#endif
}

static BOOL camera_write_full(int fd, const void *buffer, size_t length) {
    const uint8_t *bytes = (const uint8_t *)buffer;
    while (length > 0) {
        ssize_t count = send(fd, bytes, length, MSG_NOSIGNAL);
        if (count <= 0) return NO;
        bytes += (size_t)count;
        length -= (size_t)count;
    }
    return YES;
}

static void camera_close_socket(void) {
    if (gCameraSocket >= 0) close(gCameraSocket);
    gCameraSocket = -1;
    gCameraSocketGeneration = 0;
}

static BOOL camera_send_message(uint8_t type, uint16_t flags, uint64_t pts_us,
                                uint64_t generation, const void *payload, uint32_t length) {
    if (length > RCTL_CAMERA_MAX_PAYLOAD) return NO;
    if (gCameraSocket < 0 || gCameraSocketGeneration != generation) {
        camera_close_socket();
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return NO;
        struct sockaddr_in address;
        memset(&address, 0, sizeof(address));
        address.sin_family = AF_INET;
        address.sin_port = htons(RCTL_CAMERA_INGEST_PORT);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
            close(fd);
            return NO;
        }
        struct timeval timeout = {.tv_sec = 2, .tv_usec = 0};
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        gCameraSocket = fd;
        gCameraSocketGeneration = generation;

        NSString *owner = [NSBundle mainBundle].bundleIdentifier ?: [NSProcessInfo processInfo].processName ?: @"unknown";
        NSData *ownerData = [owner dataUsingEncoding:NSUTF8StringEncoding];
        rctl_camera_header hello = {
            htonl(RCTL_CAMERA_MAGIC), RCTL_CAMERA_VERSION, RCTL_CAMERA_MSG_HELLO,
            htons(0), htonl((uint32_t)ownerData.length), camera_hton64(0), camera_hton64(generation)
        };
        if (!camera_write_full(fd, &hello, sizeof(hello)) ||
            (ownerData.length && !camera_write_full(fd, ownerData.bytes, ownerData.length))) {
            camera_close_socket();
            return NO;
        }
    }

    rctl_camera_header header = {
        htonl(RCTL_CAMERA_MAGIC), RCTL_CAMERA_VERSION, type, htons(flags), htonl(length),
        camera_hton64(pts_us), camera_hton64(generation)
    };
    if (!camera_write_full(gCameraSocket, &header, sizeof(header)) ||
        (length && !camera_write_full(gCameraSocket, payload, length))) {
        camera_close_socket();
        return NO;
    }
    return YES;
}

static void camera_encoded(const uint8_t *data, size_t length, bool keyframe,
                           int64_t pts_us, void *context) {
    uint64_t generation = (uint64_t)(uintptr_t)context;
    if (!data || !length || length > RCTL_CAMERA_MAX_PAYLOAD) return;
    if (atomic_fetch_add(&gCameraPendingFrames, 1) >= 3) {
        atomic_fetch_sub(&gCameraPendingFrames, 1);
        return;
    }
    NSData *copy = [NSData dataWithBytes:data length:length];
    dispatch_async(gCameraNetworkQueue, ^{
        camera_send_message(RCTL_CAMERA_MSG_VIDEO,
                            keyframe ? RCTL_CAMERA_FLAG_KEYFRAME : 0,
                            pts_us > 0 ? (uint64_t)pts_us : 0, generation,
                            copy.bytes, (uint32_t)copy.length);
        atomic_fetch_sub(&gCameraPendingFrames, 1);
    });
}

static void camera_capture_output(id self, SEL command, id output,
                                  CMSampleBufferRef sampleBuffer, id connection) {
    (void)self;
    (void)command;
    (void)output;
    (void)connection;
    if (!atomic_load(&gCameraRunning) || !sampleBuffer) return;
    CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixel) return;
    int width = (int)CVPixelBufferGetWidth(pixel);
    int height = (int)CVPixelBufferGetHeight(pixel);
    if (!gCameraEncoder || width != gCameraWidth || height != gCameraHeight) {
        if (gCameraEncoder) rctl_encoder_destroy(gCameraEncoder);
        gCameraWidth = width;
        gCameraHeight = height;
        gCameraEncoder = rctl_encoder_create(width, height, width, height,
            gCameraFPS, gCameraBitrate, camera_encoded,
            (void *)(uintptr_t)gCameraGeneration);
        if (!gCameraEncoder) return;
    }
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime scaled = CMTIME_IS_VALID(pts) ? CMTimeConvertScale(pts, 1000000, kCMTimeRoundingMethod_Default) : kCMTimeZero;
    int64_t minInterval = 1000000 / (gCameraFPS > 0 ? gCameraFPS : 10);
    if (gCameraLastEncodedPTS && scaled.value - gCameraLastEncodedPTS < minInterval) return;
    gCameraLastEncodedPTS = scaled.value;
    rctl_encoder_encode_pixel_buffer(gCameraEncoder, pixel, scaled.value);
}

static id camera_create_delegate(void) {
    static Class delegateClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class created = objc_allocateClassPair([NSObject class],
            "RCTLCameraFrameDelegate", 0);
        if (created && class_addMethod(created,
                @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                (IMP)camera_capture_output, "v@:@@@")) {
            objc_registerClassPair(created);
            delegateClass = created;
        } else {
            if (created) objc_disposeClassPair(created);
            delegateClass = objc_getClass("RCTLCameraFrameDelegate");
        }
    });
    return delegateClass ? [delegateClass new] : nil;
}

static id camera_device_for_position(Class deviceClass, int position) {
    NSArray *devices = ((id (*)(id, SEL, id))objc_msgSend)((id)deviceClass,
        NSSelectorFromString(@"devicesWithMediaType:"), @"vide");
    for (id device in devices) {
        long candidate = ((long (*)(id, SEL))objc_msgSend)(device, NSSelectorFromString(@"position"));
        if (candidate == position) return device;
    }
    return ((id (*)(id, SEL, id))objc_msgSend)((id)deviceClass,
        NSSelectorFromString(@"defaultDeviceWithMediaType:"), @"vide");
}

static void camera_configure_connection(id output) {
    id connection = ((id (*)(id, SEL, id))objc_msgSend)(output,
        NSSelectorFromString(@"connectionWithMediaType:"), @"vide");
    if (!connection) return;
    long orientation = [UIApplication sharedApplication].statusBarOrientation;
    if (orientation >= 1 && orientation <= 4 &&
        ((BOOL (*)(id, SEL))objc_msgSend)(connection, NSSelectorFromString(@"isVideoOrientationSupported")))
        ((void (*)(id, SEL, long))objc_msgSend)(connection, NSSelectorFromString(@"setVideoOrientation:"), orientation);
    if (gCameraPosition == 2 &&
        ((BOOL (*)(id, SEL))objc_msgSend)(connection, NSSelectorFromString(@"isVideoMirroringSupported"))) {
        if ([connection respondsToSelector:NSSelectorFromString(@"setAutomaticallyAdjustsVideoMirroring:")])
            ((void (*)(id, SEL, BOOL))objc_msgSend)(connection,
                NSSelectorFromString(@"setAutomaticallyAdjustsVideoMirroring:"), NO);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(connection, NSSelectorFromString(@"setVideoMirrored:"), YES);
    }
}

static void camera_stop_locked(void) {
    if (gCameraSession && [gCameraSession respondsToSelector:NSSelectorFromString(@"stopRunning")])
        ((void (*)(id, SEL))objc_msgSend)(gCameraSession, NSSelectorFromString(@"stopRunning"));
    if (gCameraOutput && [gCameraOutput respondsToSelector:NSSelectorFromString(@"setSampleBufferDelegate:queue:")])
        ((void (*)(id, SEL, id, dispatch_queue_t))objc_msgSend)(gCameraOutput,
            NSSelectorFromString(@"setSampleBufferDelegate:queue:"), nil, NULL);
    if (gCameraEncoder) rctl_encoder_destroy(gCameraEncoder);
    gCameraEncoder = NULL;
    gCameraSession = nil;
    gCameraOutput = nil;
    gCameraDelegate = nil;
    atomic_store(&gCameraRunning, false);
    gCameraLastEncodedPTS = 0;
    camera_set_tcc_active(NO);
    dispatch_async(gCameraNetworkQueue, ^{ camera_close_socket(); });
}

static BOOL camera_start_locked(void) {
    camera_stop_locked();
    camera_set_tcc_active(YES);
    dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY);
    __block BOOL ready = NO;
    do {
        Class deviceClass = NSClassFromString(@"AVCaptureDevice");
        Class inputClass = NSClassFromString(@"AVCaptureDeviceInput");
        Class sessionClass = NSClassFromString(@"AVCaptureSession");
        Class outputClass = NSClassFromString(@"AVCaptureVideoDataOutput");
        if (!deviceClass || !inputClass || !sessionClass || !outputClass) break;

        id device = camera_device_for_position(deviceClass, gCameraPosition);
        if (!device) break;
        NSError *configurationError = nil;
        BOOL locked = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(device,
            NSSelectorFromString(@"lockForConfiguration:"), &configurationError);
        if (locked) {
            CMTime frameDuration = CMTimeMake(1, gCameraFPS > 0 ? gCameraFPS : 10);
            if ([device respondsToSelector:NSSelectorFromString(@"setActiveVideoMinFrameDuration:")])
                ((void (*)(id, SEL, CMTime))objc_msgSend)(device,
                    NSSelectorFromString(@"setActiveVideoMinFrameDuration:"), frameDuration);
            if ([device respondsToSelector:NSSelectorFromString(@"setActiveVideoMaxFrameDuration:")])
                ((void (*)(id, SEL, CMTime))objc_msgSend)(device,
                    NSSelectorFromString(@"setActiveVideoMaxFrameDuration:"), frameDuration);
            ((void (*)(id, SEL))objc_msgSend)(device, NSSelectorFromString(@"unlockForConfiguration"));
        }
        NSError *error = nil;
        id input = ((id (*)(id, SEL, id, NSError **))objc_msgSend)((id)inputClass,
            NSSelectorFromString(@"deviceInputWithDevice:error:"), device, &error);
        if (!input) break;
        id session = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)(
            (id)sessionClass, NSSelectorFromString(@"alloc")), NSSelectorFromString(@"init"));
        ((void (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"setSessionPreset:"),
            @"AVCaptureSessionPreset640x480");
        if (!((BOOL (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"canAddInput:"), input)) break;
        ((void (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"addInput:"), input);

        id output = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)(
            (id)outputClass, NSSelectorFromString(@"alloc")), NSSelectorFromString(@"init"));
        ((void (*)(id, SEL, BOOL))objc_msgSend)(output,
            NSSelectorFromString(@"setAlwaysDiscardsLateVideoFrames:"), YES);
        NSDictionary *settings = @{(__bridge id)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)};
        ((void (*)(id, SEL, id))objc_msgSend)(output, NSSelectorFromString(@"setVideoSettings:"), settings);
        if (!((BOOL (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"canAddOutput:"), output)) break;
        ((void (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"addOutput:"), output);

        gCameraDelegate = camera_create_delegate();
        if (!gCameraDelegate) break;
        ((void (*)(id, SEL, id, dispatch_queue_t))objc_msgSend)(output,
            NSSelectorFromString(@"setSampleBufferDelegate:queue:"), gCameraDelegate, gCameraQueue);
        gCameraSession = session;
        gCameraOutput = output;
        camera_configure_connection(output);
        atomic_store(&gCameraRunning, true);
        ((void (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"startRunning"));
        ready = ((BOOL (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"isRunning"));
    } while (0);
    if (!ready) camera_stop_locked();
    return ready;
}

static NSDictionary *camera_fetch_state(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(8080);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return nil;
    }
    struct timeval timeout = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    const char *request = "GET /v1/cam_agent_state HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    if (!camera_write_full(fd, request, strlen(request))) {
        close(fd);
        return nil;
    }
    NSMutableData *response = [NSMutableData data];
    uint8_t buffer[1024];
    for (;;) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count <= 0) break;
        [response appendBytes:buffer length:(NSUInteger)count];
        if (response.length > 8192) break;
    }
    close(fd);
    NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange boundary = [response rangeOfData:separator options:0 range:NSMakeRange(0, response.length)];
    if (boundary.location == NSNotFound) return nil;
    NSData *body = [response subdataWithRange:NSMakeRange(NSMaxRange(boundary), response.length - NSMaxRange(boundary))];
    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

void rctl_camera_agent_sync(void) {
    if (atomic_exchange(&gCameraSyncInFlight, true)) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *state = camera_fetch_state();
        dispatch_async(gCameraQueue, ^{
            atomic_store(&gCameraSyncInFlight, false);
            UIApplication *application = [UIApplication sharedApplication];
            BOOL foreground = application && application.applicationState == UIApplicationStateActive;
            BOOL enabled = [state[@"enabled"] boolValue] && foreground;
            uint64_t generation = [state[@"generation"] unsignedLongLongValue];
            int position = [state[@"position"] isEqual:@"front"] ? 2 : 1;
            int fps = [state[@"fps"] intValue];
            int bitrate = [state[@"bitrate"] intValue];
            BOOL changed = generation != gCameraGeneration || position != gCameraPosition ||
                           fps != gCameraFPS || bitrate != gCameraBitrate;
            if (!enabled) {
                if (atomic_load(&gCameraRunning)) camera_stop_locked();
                return;
            }
            if (!atomic_load(&gCameraRunning) || changed) {
                gCameraGeneration = generation;
                gCameraPosition = position;
                gCameraFPS = fps > 0 ? fps : 10;
                gCameraBitrate = bitrate > 0 ? bitrate : 1500000;
                camera_start_locked();
            }
        });
    });
}

static void camera_darwin_sync(CFNotificationCenterRef center, void *observer,
                               CFStringRef name, const void *object, CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)object; (void)info;
    rctl_camera_agent_sync();
}

static void camera_darwin_keyframe(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)object; (void)info;
    dispatch_async(gCameraQueue, ^{ if (gCameraEncoder) rctl_encoder_request_keyframe(gCameraEncoder); });
}

void rctl_camera_agent_initialize(rctl_camera_tcc_callback tcc_callback) {
    NSString *process = [NSProcessInfo processInfo].processName;
    if ([process isEqualToString:@"SpringBoard"]) return;
    gCameraTCCCallback = tcc_callback;
    gCameraQueue = dispatch_queue_create("com.greatlove.rctl.camera.capture", DISPATCH_QUEUE_SERIAL);
    gCameraNetworkQueue = dispatch_queue_create("com.greatlove.rctl.camera.network", DISPATCH_QUEUE_SERIAL);
    atomic_store(&gCameraPendingFrames, 0);
    atomic_store(&gCameraSyncInFlight, false);

    NSNotificationCenter *notifications = [NSNotificationCenter defaultCenter];
    [notifications addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        (void)note; rctl_camera_agent_sync();
    }];
    [notifications addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        (void)note; dispatch_async(gCameraQueue, ^{ if (atomic_load(&gCameraRunning)) camera_stop_locked(); });
    }];
    [notifications addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        (void)note;
        dispatch_async(gCameraQueue, ^{
            if (atomic_load(&gCameraRunning)) camera_start_locked();
        });
    }];

    CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(darwin, NULL, camera_darwin_sync,
        CFSTR("com.greatlove.rctl.cam.sync"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(darwin, NULL, camera_darwin_keyframe,
        CFSTR("com.greatlove.rctl.cam.keyframe"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    gCameraStateTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(gCameraStateTimer,
        dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC,
        500 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gCameraStateTimer, ^{
        UIApplication *application = [UIApplication sharedApplication];
        if (application.applicationState == UIApplicationStateActive)
            rctl_camera_agent_sync();
    });
    dispatch_resume(gCameraStateTimer);
    rctl_camera_agent_sync();
}
