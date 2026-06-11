# Diagnostic-only mediaserverd audio probe.
#
# This target is intentionally NOT listed in the top-level SUBPROJECTS and is not
# shipped in the normal rctl package. Build it manually with:
#   make -C audioprobe
#
# Loading it into mediaserverd is a separate, explicit RE step.

TARGET := iphone:clang:14.5:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = rctlaudioprobe
rctlaudioprobe_FILES = rctlaudioprobe.xm
rctlaudioprobe_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
rctlaudioprobe_FRAMEWORKS = Foundation CoreFoundation

include $(THEOS)/makefiles/tweak.mk
