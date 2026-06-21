# rctlcap — tweak injected into every app (UIKit filter). Captures a camera still
# in the FRONTMOST app (the only valid camera client) on a Darwin-notification pulse.
TARGET := iphone:clang:14.5:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = rctlcap
rctlcap_FILES = rctlcap.xm
rctlcap_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
rctlcap_FRAMEWORKS = UIKit Foundation CoreFoundation AudioToolbox

include $(THEOS)/makefiles/tweak.mk
