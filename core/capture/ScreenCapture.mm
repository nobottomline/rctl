// ScreenCapture.mm — render the live display into an IOSurface.
//
// CARenderServerRenderDisplay only writes pixels when called from inside the
// render-server process (SpringBoard); a standalone daemon gets blank frames.
// The build SDK is stripped, so the render-server symbol is dlsym'd at runtime.

#import "capture/ScreenCapture.h"
#import "capture/DisplayGeometry.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdio.h>
#import <unistd.h>
#include <stdlib.h>

typedef void (*CARenderServerRenderDisplay_f)(uint32_t client, CFStringRef display,
                                              IOSurfaceRef surface, int x, int y);

static CARenderServerRenderDisplay_f gRender = NULL;
static CFStringRef gDisplayName = NULL;
static id gDisplay = nil;
static uint32_t gPowerAssertionID = 0;
static bool gIdleTimerStateSaved = false;
static bool gPreviousIdleTimerDisabled = false;

// Bind geometry and rendering to the same main display, never an external panel.
static id main_display(void) {
    Class cls = NSClassFromString(@"CADisplay");
    if (!cls) return nil;
    SEL main = NSSelectorFromString(@"mainDisplay");
    if ([cls respondsToSelector:main]) {
        id display = ((id (*)(id, SEL))objc_msgSend)(cls, main);
        if (display) return display;
    }
    if (![cls respondsToSelector:NSSelectorFromString(@"displays")]) return nil;
    NSArray *displays = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"displays"));
    for (id d in displays) {
        SEL external = NSSelectorFromString(@"isExternal");
        if (![d respondsToSelector:external] || ((BOOL (*)(id, SEL))objc_msgSend)(d, external)) continue;
        return d;
    }
    return nil;
}

static void ensure_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
        gRender = (CARenderServerRenderDisplay_f)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        NSString *dn = nil;
        @try {
            gDisplay = main_display();
            id name = [gDisplay valueForKey:@"name"];
            if ([name isKindOfClass:NSString.class] && [name length]) dn = name;
        } @catch (NSException *exception) {
            gDisplay = nil;
        }
        gDisplayName = dn ? (CFStringRef)CFBridgingRetain(dn) : CFSTR("LCD");
        fprintf(stderr, "[capture] init render=%p display=%s\n",
                (void*)gRender, dn ? dn.UTF8String : "LCD");
    });
}

static void set_idle_timer_disabled_on_main(bool disabled) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    if (disabled) {
        if (!gIdleTimerStateSaved) {
            gPreviousIdleTimerDisabled = app.idleTimerDisabled;
            gIdleTimerStateSaved = true;
        }
        app.idleTimerDisabled = YES;
    } else if (gIdleTimerStateSaved) {
        app.idleTimerDisabled = gPreviousIdleTimerDisabled;
        gIdleTimerStateSaved = false;
    }
}

static void set_idle_timer_disabled(bool disabled) {
    if ([NSThread isMainThread]) {
        set_idle_timer_disabled_on_main(disabled);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ set_idle_timer_disabled_on_main(disabled); });
    }
}

void rctl_capture_wake_display(void) {
    set_idle_timer_disabled(true);
}

void rctl_capture_undim(void) {
    set_idle_timer_disabled(true);
}

void rctl_capture_set_keep_awake(bool awake) {
    typedef int (*PMAssert_f)(CFStringRef type, uint32_t level, CFStringRef name, uint32_t *out);
    typedef int (*PMRelease_f)(uint32_t assertion);
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (awake) {
        set_idle_timer_disabled(true);
        if (gPowerAssertionID) return;
        PMAssert_f create = (PMAssert_f)dlsym(RTLD_DEFAULT, "IOPMAssertionCreateWithName");
        if (create) {
            uint32_t assertion = 0;
            int result = create(CFSTR("PreventUserIdleDisplaySleep"), 255,
                                CFSTR("rctl remote session"), &assertion);
            if (result == 0) gPowerAssertionID = assertion;
            fprintf(stderr, "[capture] keep-awake acquire result=%d id=%u\n",
                    result, assertion);
        }
    } else {
        set_idle_timer_disabled(false);
        if (!gPowerAssertionID) return;
        PMRelease_f release = (PMRelease_f)dlsym(RTLD_DEFAULT, "IOPMAssertionRelease");
        int result = release ? release(gPowerAssertionID) : -1;
        fprintf(stderr, "[capture] keep-awake release result=%d id=%u\n",
                result, gPowerAssertionID);
        gPowerAssertionID = 0;
    }
}

static bool display_geometry(rctl_display_geometry *geometry) {
    ensure_init();
    UIScreen *s = [UIScreen mainScreen];
    CGSize px = s.nativeBounds.size;
    if (px.width <= 0 || px.height <= 0) {
        CGFloat scale = s.scale > 0 ? s.scale : 1.0;
        CGSize fixed = s.fixedCoordinateSpace.bounds.size;
        px = CGSizeMake(fixed.width * scale, fixed.height * scale);
    }
    NSString *orientation = nil;
    NSValue *bounds = nil;
    @try {
        id o = [gDisplay valueForKey:@"nativeOrientation"];
        id b = [gDisplay valueForKey:@"bounds"];
        if ([o isKindOfClass:NSString.class] && [b isKindOfClass:NSValue.class] &&
            !strcmp([b objCType], @encode(CGRect))) {
            orientation = o;
            bounds = b;
        }
    } @catch (NSException *exception) {
        // Older/private API variants retain the established UIKit-only path.
    }
    CGSize render = bounds ? bounds.CGRectValue.size : px;
    const char *rotation = orientation ? orientation.UTF8String : "rot0";
    bool valid = rctl_display_geometry_resolve(px.width, px.height, render.width,
                                               render.height, rotation, geometry);
    fprintf(stderr, "[capture] geometry UIKit=%.0fx%.0f render=%.0fx%.0f native=%s source=%s valid=%d\n",
            px.width, px.height, render.width, render.height, rotation,
            bounds ? "CADisplay" : "UIKit-fallback", valid);
    return valid;
}

struct rctl_capture {
    IOSurfaceRef native;
    IOSurfaceRef canonical;
    unsigned char rotation;
    bool failure_logged;
};

static IOSurfaceRef create_surface(size_t w, size_t h) {
    NSDictionary *props = @{
        (__bridge id)kIOSurfaceWidth:           @(w),
        (__bridge id)kIOSurfaceHeight:          @(h),
        (__bridge id)kIOSurfaceBytesPerElement: @(4),
        (__bridge id)kIOSurfacePixelFormat:     @((uint32_t)0x42475241), // 'BGRA'
        @"IOSurfaceIsGlobal":                   @YES,
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)props);
}

rctl_capture *rctl_capture_create(size_t *outW, size_t *outH) {
    if (outW) *outW = 0;
    if (outH) *outH = 0;
    rctl_display_geometry geometry;
    if (!display_geometry(&geometry) || !gRender) return NULL;
    rctl_capture *capture = (rctl_capture *)calloc(1, sizeof(rctl_capture));
    if (!capture) return NULL;
    capture->rotation = geometry.rotation;
    capture->native = create_surface(geometry.render_width, geometry.render_height);
    if (capture->rotation) capture->canonical = create_surface(geometry.width, geometry.height);
    if (!capture->native || (capture->rotation && !capture->canonical)) {
        rctl_capture_destroy(capture);
        return NULL;
    }
    if (outW) *outW = geometry.width;
    if (outH) *outH = geometry.height;
    return capture;
}

void rctl_capture_destroy(rctl_capture *capture) {
    if (!capture) return;
    if (capture->canonical) CFRelease(capture->canonical);
    if (capture->native) CFRelease(capture->native);
    free(capture);
}

IOSurfaceRef rctl_capture_render(rctl_capture *capture) {
    if (!capture || !gRender) return NULL;
    gRender(0, gDisplayName, capture->native, 0, 0);
    if (!capture->rotation) return capture->native;

    bool ok = false;
    if (IOSurfaceLock(capture->native, kIOSurfaceLockReadOnly, NULL) == 0) {
        if (IOSurfaceLock(capture->canonical, 0, NULL) == 0) {
            vImage_Buffer src = {IOSurfaceGetBaseAddress(capture->native),
                IOSurfaceGetHeight(capture->native), IOSurfaceGetWidth(capture->native),
                IOSurfaceGetBytesPerRow(capture->native)};
            vImage_Buffer dst = {IOSurfaceGetBaseAddress(capture->canonical),
                IOSurfaceGetHeight(capture->canonical), IOSurfaceGetWidth(capture->canonical),
                IOSurfaceGetBytesPerRow(capture->canonical)};
            ok = rctl_display_normalize(&src, &dst, capture->rotation);
            IOSurfaceUnlock(capture->canonical, 0, NULL);
        }
        IOSurfaceUnlock(capture->native, kIOSurfaceLockReadOnly, NULL);
    }
    if (!ok && !capture->failure_logged) {
        fprintf(stderr, "[capture] panel normalization failed; dropping frame\n");
        capture->failure_logged = true;
    }
    return ok ? capture->canonical : NULL;
}

int rctl_surface_to_png(IOSurfaceRef dst, const char *path) {
    if (!dst || !path) return 4;
    @autoreleasepool {
        int rc = 4;
        IOSurfaceLock(dst, kIOSurfaceLockReadOnly, NULL);
        size_t w = IOSurfaceGetWidth(dst), h = IOSurfaceGetHeight(dst);
        void *base = IOSurfaceGetBaseAddress(dst);
        size_t bpr = IOSurfaceGetBytesPerRow(dst);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
        if (img) {
            CFStringRef p   = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
            CFURLRef    url = CFURLCreateWithFileSystemPath(NULL, p, kCFURLPOSIXPathStyle, false);
            CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
            if (dest) {
                CGImageDestinationAddImage(dest, img, NULL);
                rc = CGImageDestinationFinalize(dest) ? 0 : 5;
                CFRelease(dest);
            }
            CFRelease(url); CFRelease(p);
            CGImageRelease(img);
        }
        if (ctx) CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
        IOSurfaceUnlock(dst, kIOSurfaceLockReadOnly, NULL);
        return rc;
    }
}

int rctl_capture_one_png(const char *path) {
    @autoreleasepool {
        rctl_capture_wake_display();
        size_t w = 0, h = 0;
        rctl_capture *capture = rctl_capture_create(&w, &h);
        if (!capture) { fprintf(stderr, "[capture] FAIL: no surface\n"); return 2; }
        IOSurfaceRef dst = rctl_capture_render(capture);
        int rc = rctl_surface_to_png(dst, path);
        rctl_capture_destroy(capture);
        return rc;
    }
}
