// ScreenCapture.mm — render the live display into an IOSurface.
//
// CARenderServerRenderDisplay only writes pixels when called from inside the
// render-server process (SpringBoard); a standalone daemon gets blank frames.
// The build SDK is stripped, so the render-server symbol is dlsym'd at runtime.

#import "capture/ScreenCapture.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdio.h>
#import <unistd.h>

typedef void (*CARenderServerRenderDisplay_f)(uint32_t client, CFStringRef display,
                                              IOSurfaceRef surface, int x, int y);
typedef void (*SBSUndimScreen_f)(void);

static CARenderServerRenderDisplay_f gRender = NULL;
static CFStringRef gDisplayName = NULL;

// Enumerate CADisplay displays and return the first usable name (usually "LCD").
static NSString *pick_main_display_name(void) {
    Class cls = NSClassFromString(@"CADisplay");
    if (!cls) return nil;
    NSArray *displays = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"displays"));
    for (id d in displays) {
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(d, NSSelectorFromString(@"name"));
        if (name.length) return name;
    }
    return nil;
}

static void ensure_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
        gRender = (CARenderServerRenderDisplay_f)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        NSString *dn = pick_main_display_name();
        gDisplayName = dn ? (CFStringRef)CFBridgingRetain(dn) : CFSTR("LCD");
        fprintf(stderr, "[capture] init render=%p display=%s\n",
                (void*)gRender, dn ? dn.UTF8String : "LCD");
    });
}

static SBSUndimScreen_f gUndim = NULL;
static void ensure_undim(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        gUndim = (SBSUndimScreen_f)dlsym(RTLD_DEFAULT, "SBSUndimScreen");
    });
}

void rctl_capture_wake_display(void) {
    ensure_undim();
    if (gUndim) { gUndim(); usleep(350000); }
}

void rctl_capture_undim(void) {
    ensure_undim();
    if (gUndim) gUndim();
}

void rctl_capture_keep_awake(void) {
    static uint32_t aid = 0;
    if (aid) return; // already holding an assertion
    typedef int (*PMAssert_f)(CFStringRef type, uint32_t level, CFStringRef name, uint32_t *out);
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    PMAssert_f f = (PMAssert_f)dlsym(RTLD_DEFAULT, "IOPMAssertionCreateWithName");
    if (f) {
        int r = f(CFSTR("PreventUserIdleDisplaySleep"), 255, CFSTR("rctl"), &aid);
        fprintf(stderr, "[capture] keep_awake r=%d id=%u\n", r, aid);
    }
}

static CGSize main_display_pixels(void) {
    UIScreen *s = [UIScreen mainScreen];
    CGRect nb = s.nativeBounds;
    if (nb.size.width > 0 && nb.size.height > 0) return nb.size;
    CGFloat scale = s.scale > 0 ? s.scale : 1.0;
    return CGSizeMake(s.bounds.size.width * scale, s.bounds.size.height * scale);
}

IOSurfaceRef rctl_capture_create_surface(double scale, size_t *outW, size_t *outH) {
    CGSize px = main_display_pixels();
    if (scale <= 0) scale = 1.0;
    size_t w = ((size_t)(px.width  * scale)) & ~1UL; // even dims for H.264 chroma
    size_t h = ((size_t)(px.height * scale)) & ~1UL;
    if (outW) *outW = w;
    if (outH) *outH = h;
    if (w == 0 || h == 0) return NULL;
    NSDictionary *props = @{
        (__bridge id)kIOSurfaceWidth:           @(w),
        (__bridge id)kIOSurfaceHeight:          @(h),
        (__bridge id)kIOSurfaceBytesPerElement: @(4),
        (__bridge id)kIOSurfacePixelFormat:     @((uint32_t)0x42475241), // 'BGRA'
        @"IOSurfaceIsGlobal":                   @YES,
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)props);
}

void rctl_capture_render(IOSurfaceRef dst) {
    ensure_init();
    if (gRender && dst) gRender(0, gDisplayName, dst, 0, 0);
}

int rctl_capture_one_png(const char *path) {
    @autoreleasepool {
        rctl_capture_wake_display();
        size_t w = 0, h = 0;
        IOSurfaceRef dst = rctl_capture_create_surface(1.0, &w, &h);
        if (!dst) { fprintf(stderr, "[capture] FAIL: no surface\n"); return 2; }
        rctl_capture_render(dst);

        int rc = 4;
        IOSurfaceLock(dst, kIOSurfaceLockReadOnly, NULL);
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
        CFRelease(dst);
        return rc;
    }
}
