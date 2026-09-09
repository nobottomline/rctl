#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdint.h>

static inline bool rctl_capture_pcm_supported(const AudioStreamBasicDescription &f) {
    if (f.mFormatID != kAudioFormatLinearPCM || !isfinite(f.mSampleRate) ||
        f.mSampleRate < 8000 || f.mSampleRate > 192000 ||
        f.mChannelsPerFrame < 1 || f.mChannelsPerFrame > 2 ||
        (f.mFormatFlags & kAudioFormatFlagIsBigEndian) ||
        !(f.mFormatFlags & kAudioFormatFlagIsPacked)) return false;
    bool floating = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    bool integer = (f.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    if (!((floating && !integer && f.mBitsPerChannel == 32) ||
          (integer && !floating && f.mBitsPerChannel == 16))) return false;
    unsigned channels = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : f.mChannelsPerFrame;
    return f.mBytesPerFrame == channels * (f.mBitsPerChannel / 8);
}

static inline int16_t rctl_capture_float_s16(float v) {
    if (!isfinite(v)) return 0;
    if (v > 1) v = 1;
    if (v < -1) v = -1;
    return static_cast<int16_t>(v * 32767.0f);
}

static inline bool rctl_capture_plane_fits(const AudioBuffer &b, unsigned frames, unsigned bytesPerSample) {
    return b.mData && b.mNumberChannels == 1 && bytesPerSample > 0 && frames <= b.mDataByteSize / bytesPerSample;
}
