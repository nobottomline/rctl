#pragma once

#import <AudioToolbox/AudioToolbox.h>

#ifdef __cplusplus
extern "C" {
#endif

void rctl_virtual_mic_activate(void);
OSStatus rctl_virtual_mic_process(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                                  const AudioTimeStamp *timestamp, UInt32 bus,
                                  UInt32 frames, AudioBufferList *buffers,
                                  OSStatus original_status);

#ifdef __cplusplus
}
#endif
