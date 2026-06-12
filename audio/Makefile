# rctlaudio: guarded mediaserverd system-audio agent.
#
# Built from the top-level package stage as an inactive payload. rctld copies it
# into the active MobileSubstrate path only while browser audio capture is enabled.

TARGET := iphone:clang:14.5:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = rctlaudio
rctlaudio_FILES = rctlaudio.xm
rctlaudio_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I../core
rctlaudio_FRAMEWORKS = Foundation CoreFoundation AudioToolbox

include $(THEOS)/makefiles/tweak.mk
