# rctlmsd — MobileSubstrate tweak injected into mediaserverd to defeat the
# foreground-only camera gate (so capture works from any foreground app).
TARGET := iphone:clang:14.5:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = rctlmsd
rctlmsd_FILES = rctlmsd.xm
rctlmsd_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS)/makefiles/tweak.mk
