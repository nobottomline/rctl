# Safe mediaserverd audio-source skeleton.
#
# This target is intentionally NOT listed in the top-level SUBPROJECTS and is not
# shipped in the normal rctl package. It does not hook audio paths; when loaded
# with the explicit test marker present it sends a short synthetic PCM stream to
# rctld's audio ingest socket.

TARGET := iphone:clang:14.5:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = rctlaudiosource
rctlaudiosource_FILES = rctlaudiosource.xm
rctlaudiosource_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I../core
rctlaudiosource_FRAMEWORKS = Foundation CoreFoundation

include $(THEOS)/makefiles/tweak.mk
