#include "audio/CapturePCM.h"
#include <cassert>
#include <limits>
#include <cstdio>

int main() {
    AudioStreamBasicDescription f = {};
    f.mFormatID = kAudioFormatLinearPCM; f.mSampleRate = 48000;
    f.mChannelsPerFrame = 2; f.mBitsPerChannel = 32; f.mBytesPerFrame = 8;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    assert(rctl_capture_pcm_supported(f));
    f.mBytesPerFrame = 4;
    assert(!rctl_capture_pcm_supported(f));
    f.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
    assert(rctl_capture_pcm_supported(f));
    f.mSampleRate = std::numeric_limits<double>::quiet_NaN();
    assert(!rctl_capture_pcm_supported(f));
    float samples[4] = {};
    AudioBuffer b = {1, sizeof(samples), samples};
    assert(rctl_capture_plane_fits(b, 4, 4));
    assert(!rctl_capture_plane_fits(b, 5, 4));
    b.mDataByteSize = 0;
    assert(!rctl_capture_plane_fits(b, 1, 4));
    assert(rctl_capture_float_s16(std::numeric_limits<float>::quiet_NaN()) == 0);
    assert(rctl_capture_float_s16(std::numeric_limits<float>::infinity()) == 0);
    assert(rctl_capture_float_s16(2) == 32767);
    assert(rctl_capture_float_s16(-2) == -32767);
    puts("capture PCM bounds and format tests passed");
}
