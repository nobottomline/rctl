// H264Encoder.mm — VideoToolbox hardware H.264 encoder.
//
// Input: BGRA IOSurface frames. Output: Annex-B access units (start-code framed),
// with SPS/PPS prepended on each keyframe so the stream is self-contained.

#import "encode/H264Encoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTPixelTransferProperties.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

// VTPixelTransferSession.h is missing from this (stripped) SDK; declare what we use.
// The symbols live in VideoToolbox.framework, so linking resolves them.
typedef struct OpaqueVTPixelTransferSession *VTPixelTransferSessionRef;
extern "C" {
OSStatus VTPixelTransferSessionCreate(CFAllocatorRef allocator, VTPixelTransferSessionRef *out);
OSStatus VTPixelTransferSessionTransferImage(VTPixelTransferSessionRef session,
                                             CVPixelBufferRef src, CVPixelBufferRef dst);
void VTPixelTransferSessionInvalidate(VTPixelTransferSessionRef session);
}

struct rctl_encoder {
    VTCompressionSessionRef session;
    VTPixelTransferSessionRef transfer; // GPU scaler (NULL if no scaling)
    CVPixelBufferPoolRef pool;          // dest buffers (NULL if no scaling)
    rctl_nal_cb cb;
    void *ctx;
    int srcW, srcH, dstW, dstH;
    int force_keyframe; // set by rctl_encoder_request_keyframe; consumed in encode
};

static const uint8_t kStartCode[4] = { 0, 0, 0, 1 };

// Growable byte buffer.
typedef struct { uint8_t *p; size_t len, cap; } buf_t;
static void buf_append(buf_t *b, const void *data, size_t n) {
    if (b->len + n > b->cap) { b->cap = (b->len + n) * 2 + 1024; b->p = (uint8_t *)realloc(b->p, b->cap); }
    memcpy(b->p + b->len, data, n);
    b->len += n;
}

static void emit_annexb(rctl_encoder *e, CMSampleBufferRef sb, bool keyframe) {
    buf_t out = {0};

    if (keyframe) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
        size_t count = 0;
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, NULL, NULL, &count, NULL);
        for (size_t i = 0; i < count; i++) {
            const uint8_t *ps = NULL; size_t psSize = 0;
            if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &psSize, NULL, NULL) == noErr) {
                buf_append(&out, kStartCode, 4);
                buf_append(&out, ps, psSize);
            }
        }
    }

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t total = 0; char *data = NULL;
    if (CMBlockBufferGetDataPointer(bb, 0, NULL, &total, &data) == noErr) {
        size_t off = 0;
        while (off + 4 <= total) {
            uint32_t nalLen = ((uint8_t)data[off] << 24) | ((uint8_t)data[off+1] << 16) |
                              ((uint8_t)data[off+2] << 8) | (uint8_t)data[off+3];
            off += 4;
            if (nalLen == 0 || off + nalLen > total) break;
            buf_append(&out, kStartCode, 4);
            buf_append(&out, data + off, nalLen);
            off += nalLen;
        }
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    CMTime ptsScaled = CMTIME_IS_VALID(pts) ? CMTimeConvertScale(pts, 1000000, kCMTimeRoundingMethod_Default)
                                            : kCMTimeZero;
    int64_t pts_us = ptsScaled.value;
    if (e->cb && out.p && out.len) e->cb(out.p, out.len, keyframe, pts_us, e->ctx);
    free(out.p);
}

static void output_cb(void *refcon, void *src, OSStatus status,
                      VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    if (status != noErr || !sb || !CMSampleBufferDataIsReady(sb)) {
        if (status != noErr) fprintf(stderr, "[enc] output status=%d\n", (int)status);
        return;
    }
    rctl_encoder *e = (rctl_encoder *)refcon;
    bool keyframe = true;
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (att && CFArrayGetCount(att)) {
        CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(att, 0);
        CFBooleanRef notSync = NULL;
        if (CFDictionaryGetValueIfPresent(d, kCMSampleAttachmentKey_NotSync, (const void **)&notSync) &&
            notSync && CFBooleanGetValue(notSync)) {
            keyframe = false;
        }
    }
    emit_annexb(e, sb, keyframe);
}

static void set_int(VTCompressionSessionRef s, CFStringRef key, int v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    VTSessionSetProperty(s, key, n);
    CFRelease(n);
}

rctl_encoder *rctl_encoder_create(int srcW, int srcH, int dstW, int dstH,
                                  int fps, int bitrate, rctl_nal_cb cb, void *ctx) {
    rctl_encoder *e = (rctl_encoder *)calloc(1, sizeof(rctl_encoder));
    e->cb = cb; e->ctx = ctx;
    e->srcW = srcW; e->srcH = srcH; e->dstW = dstW; e->dstH = dstH;

    OSStatus s = VTCompressionSessionCreate(NULL, dstW, dstH, kCMVideoCodecType_H264,
                                            NULL, NULL, NULL, output_cb, e, &e->session);
    if (s != noErr || !e->session) {
        fprintf(stderr, "[enc] VTCompressionSessionCreate failed %d\n", (int)s);
        free(e);
        return NULL;
    }

    // GPU scaler + dest pool, only when downscaling.
    if (dstW != srcW || dstH != srcH) {
        if (VTPixelTransferSessionCreate(NULL, &e->transfer) == noErr) {
            VTSessionSetProperty((VTSessionRef)e->transfer, kVTPixelTransferPropertyKey_ScalingMode,
                                 kVTScalingMode_Normal);
        }
        NSDictionary *attrs = @{
            (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (__bridge id)kCVPixelBufferWidthKey:           @(dstW),
            (__bridge id)kCVPixelBufferHeightKey:          @(dstH),
            (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &e->pool);
    }
    VTSessionSetProperty(e->session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(e->session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    set_int(e->session, kVTCompressionPropertyKey_MaxFrameDelayCount, 0); // emit each frame ASAP (low latency)
    // High profile (CABAC) — much better quality per bitrate than Baseline.
    VTSessionSetProperty(e->session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_High_AutoLevel);
    VTSessionSetProperty(e->session, kVTCompressionPropertyKey_H264EntropyMode,
                         kVTH264EntropyMode_CABAC);
    // Downscaling = the remote (WebRTC) profile: NACK + PLI recover from loss and
    // the browser pulls a keyframe on join, so use a long GOP. A periodic
    // full-intra frame is large and briefly saturates the uplink -- a visible
    // freeze every GOP -- so stretching it from 2s to ~10s removes most of them
    // (PLI still gives instant recovery when actually needed). Full-res = the LAN
    // path, which keeps the short GOP to bound new-subscriber join corruption.
    int keyint = (dstW != srcW || dstH != srcH) ? fps * 10 : fps * 2;
    set_int(e->session, kVTCompressionPropertyKey_MaxKeyFrameInterval, keyint);
    set_int(e->session, kVTCompressionPropertyKey_AverageBitRate, bitrate);
    set_int(e->session, kVTCompressionPropertyKey_ExpectedFrameRate, fps);
    VTCompressionSessionPrepareToEncodeFrames(e->session);

    fprintf(stderr, "[enc] H.264 %dx%d -> %dx%d @%dfps %dbps ready\n",
            srcW, srcH, dstW, dstH, fps, bitrate);
    return e;
}

void rctl_encoder_encode(rctl_encoder *e, IOSurfaceRef surface, int64_t pts_us) {
    if (!e || !e->session || !surface) return;

    CVPixelBufferRef src = NULL;
    if (CVPixelBufferCreateWithIOSurface(NULL, surface, NULL, &src) != kCVReturnSuccess || !src) {
        fprintf(stderr, "[enc] CVPixelBuffer fail\n");
        return;
    }

    CVPixelBufferRef frame = src; // what we hand to the encoder
    CVPixelBufferRef scaled = NULL;
    if (e->transfer && e->pool) {
        if (CVPixelBufferPoolCreatePixelBuffer(NULL, e->pool, &scaled) == kCVReturnSuccess &&
            VTPixelTransferSessionTransferImage(e->transfer, src, scaled) == noErr) {
            frame = scaled;
        }
    }

    CMTime pts = CMTimeMake(pts_us, 1000000);
    VTEncodeInfoFlags flags = 0;
    CFDictionaryRef frameProps = NULL;
    if (__atomic_exchange_n(&e->force_keyframe, 0, __ATOMIC_SEQ_CST)) {
        const void *k = kVTEncodeFrameOptionKey_ForceKeyFrame;
        const void *v = kCFBooleanTrue;
        frameProps = CFDictionaryCreate(NULL, &k, &v, 1,
                                        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    OSStatus s = VTCompressionSessionEncodeFrame(e->session, frame, pts, kCMTimeInvalid, frameProps, NULL, &flags);
    if (frameProps) CFRelease(frameProps);
    if (s != noErr) fprintf(stderr, "[enc] EncodeFrame err %d\n", (int)s);

    if (scaled) CVPixelBufferRelease(scaled);
    CVPixelBufferRelease(src);
}

void rctl_encoder_set_bitrate(rctl_encoder *e, int bitrate_bps) {
    if (!e || !e->session || bitrate_bps < 100000) return;
    set_int(e->session, kVTCompressionPropertyKey_AverageBitRate, bitrate_bps);
    // Hard cap on short bursts (~1.5x average over 1s) so a single large IDR
    // cannot blow the link budget. DataRateLimits is [bytes, seconds].
    int capBytes = (int)((double)bitrate_bps / 8.0 * 1.5);
    CFNumberRef bytesNum = CFNumberCreate(NULL, kCFNumberIntType, &capBytes);
    double oneSec = 1.0;
    CFNumberRef secNum = CFNumberCreate(NULL, kCFNumberDoubleType, &oneSec);
    const void *vals[2] = { bytesNum, secNum };
    CFArrayRef limits = CFArrayCreate(NULL, vals, 2, &kCFTypeArrayCallBacks);
    VTSessionSetProperty(e->session, kVTCompressionPropertyKey_DataRateLimits, limits);
    CFRelease(limits);
    CFRelease(bytesNum);
    CFRelease(secNum);
}

void rctl_encoder_request_keyframe(rctl_encoder *e) {
    if (!e) return;
    __atomic_store_n(&e->force_keyframe, 1, __ATOMIC_SEQ_CST);
}

void rctl_encoder_destroy(rctl_encoder *e) {
    if (!e) return;
    if (e->session) {
        VTCompressionSessionCompleteFrames(e->session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(e->session);
        CFRelease(e->session);
    }
    if (e->transfer) { VTPixelTransferSessionInvalidate(e->transfer); CFRelease(e->transfer); }
    if (e->pool) CFRelease(e->pool);
    free(e);
}
