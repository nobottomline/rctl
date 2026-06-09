# SpringBoard-injected agent: capture + VideoToolbox encode + HTTP/WebCodecs stream.
# Links the shared modules from ../core. (MVP: HTTP server lives here; transport
# moves to WebRTC + a separate daemon later.)

TARGET := iphone:clang:14.5:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = rctlsbcap
rctlsbcap_FILES = Tweak.xm \
                  ../core/capture/ScreenCapture.mm \
                  ../core/encode/H264Encoder.mm \
                  ../core/stream/CaptureSession.mm \
                  ../core/net/HttpStreamServer.mm \
                  ../core/input/TouchInjector.mm
rctlsbcap_CFLAGS = -fobjc-arc -I../core -Wno-deprecated-declarations
rctlsbcap_FRAMEWORKS = Foundation UIKit IOSurface CoreGraphics ImageIO \
                       VideoToolbox CoreMedia CoreVideo QuartzCore

include $(THEOS)/makefiles/tweak.mk
