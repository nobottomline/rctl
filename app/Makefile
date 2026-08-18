# rctlapp — app-side media agent injected into every app (UIKit filter). Brokers
# the daemon's per-app media access in the FRONTMOST app: camera stills today, the
# microphone (listen + inject) next. Driven by Darwin notifications from rctld.
TARGET := iphone:clang:14.5:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = rctlapp
rctlapp_FILES = rctlapp.xm CameraAgent.mm ../core/encode/H264Encoder.mm
rctlapp_CFLAGS = -fobjc-arc -I../core -Wno-deprecated-declarations
rctlapp_FRAMEWORKS = UIKit Foundation CoreFoundation AudioToolbox AVFoundation \
                     VideoToolbox CoreMedia CoreVideo IOSurface

include $(THEOS)/makefiles/tweak.mk
