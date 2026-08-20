TARGET := iphone:clang:14.5:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

WEBRTC := ../third_party/webrtc
MBED := $(WEBRTC)/.lib/ios/mbedtls-install
LIBCPP := $(shell xcrun --sdk iphoneos --show-sdk-path)/usr/include/c++/v1

TOOL_NAME = rctl-updater
rctl-updater_FILES = main.mm
rctl-updater_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-module-import-in-extern-c
rctl-updater_CCFLAGS = -std=gnu++17 -isystem $(LIBCPP) -I$(MBED)/include
rctl-updater_LDFLAGS = $(MBED)/lib/libmbedtls.a $(MBED)/lib/libmbedx509.a $(MBED)/lib/libmbedcrypto.a -lc++
rctl-updater_FRAMEWORKS = Foundation
rctl-updater_INSTALL_PATH = /usr/local/libexec

include $(THEOS_MAKE_PATH)/tool.mk
