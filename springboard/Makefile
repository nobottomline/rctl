# SpringBoard-injected agent: capture + VideoToolbox encode + touch/key injection.
# Streams encoded frames to the rctld daemon and receives input over a local
# socket (the network server lives in the daemon now). Links shared ../core modules.

TARGET := iphone:clang:14.5:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = rctlsbcap
rctlsbcap_FILES = Tweak.xm \
                  ../core/capture/ScreenCapture.mm \
                  ../core/encode/H264Encoder.mm \
                  ../core/stream/CaptureSession.mm \
                  ../core/input/TouchInjector.mm \
                  ../core/ipc/Ipc.c
rctlsbcap_CFLAGS = -fobjc-arc -I../core -Wno-deprecated-declarations
rctlsbcap_FRAMEWORKS = Foundation UIKit IOSurface CoreGraphics ImageIO \
                       VideoToolbox CoreMedia CoreVideo QuartzCore \
                       AVFoundation AudioToolbox

include $(THEOS)/makefiles/tweak.mk
