# SpringBoard-injected agent: capture + VideoToolbox encode + touch/key injection.
# Streams encoded frames to the rctld daemon and receives input over a local
# socket (the network server lives in the daemon now). Links shared ../core modules.

include ../mk/native-target.mk
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

# Accelerate's C++ headers need the same stripped-SDK fallback as the daemon.
LIBCPP := $(if $(wildcard $(ISYSROOT)/usr/include/c++/v1/__config),$(ISYSROOT),$(shell xcrun --sdk iphoneos --show-sdk-path))/usr/include/c++/v1

TWEAK_NAME = rctlsbcap
rctlsbcap_FILES = rctlsbcap.xm \
                  ../core/capture/ScreenCapture.mm \
                  ../core/encode/H264Encoder.mm \
                  ../core/stream/CaptureSession.mm \
                  ../core/input/TouchInjector.mm \
                  ../core/input/GameKeyboard.mm \
                  ../core/input/GamePointer.mm \
                  ../core/ipc/Ipc.c
rctlsbcap_CFLAGS = -fobjc-arc -I../core -Wno-deprecated-declarations
rctlsbcap_CCFLAGS = -isystem $(LIBCPP)
# AVFoundation/AudioToolbox are linked (not header-imported) for the FX module's
# AVSpeechSynthesizer + AudioServicesPlaySystemSound, driven via the runtime to
# dodge the AVFoundation umbrella's camera/simd module-build failure.
rctlsbcap_FRAMEWORKS = Foundation UIKit IOSurface CoreGraphics ImageIO \
                       VideoToolbox CoreMedia CoreVideo QuartzCore \
                       AVFoundation AudioToolbox Photos Accelerate

include $(THEOS)/makefiles/tweak.mk
