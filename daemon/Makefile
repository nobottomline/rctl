# rctld — root daemon (transport + automation API). Installed to /usr/local/bin,
# launched by /Library/LaunchDaemons/com.greatlove.rctld.plist (shipped via layout/).

TARGET := iphone:clang:14.5:14.0
# Keep the daemon arm64-only. On iOS 14 arm64e devices, the arm64e tool slice
# can hit pointer-auth failures while loading Objective-C metadata from the
# optional relay client. The SpringBoard tweaks still build arm64e separately.
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

# WebRTC DataChannels (libdatachannel + deps + mbedtls), cross-compiled for iOS
# by relay/experiments/webrtc-spike/build-ios.sh. Local/gitignored artifacts for
# now (feasibility) — Phase 4 will vendor them properly.
WEBRTC := ../relay/experiments/webrtc-spike
DC := $(WEBRTC)/.lib/libdatachannel
MBED := $(WEBRTC)/.lib/ios/mbedtls-install
# Theos SDKs ship no libc++ headers (the pre-existing ObjC code never used the
# STL); libdatachannel is heavy C++, so pull libc++ headers from the Xcode SDK.
LIBCPP := $(shell xcrun --sdk iphoneos --show-sdk-path)/usr/include/c++/v1

TOOL_NAME = rctld
rctld_FILES = main.mm \
              ../core/net/RelayClient.mm \
              ../core/net/HttpStreamServer.mm \
              ../core/net/Term.mm \
              ../core/net/WebRTCBridge.cpp \
              ../core/ipc/Ipc.c
rctld_CFLAGS = -fobjc-arc -I../core -Wno-deprecated-declarations
rctld_CCFLAGS = -std=gnu++17 -isystem $(LIBCPP) -I$(DC)/include -I$(DC)/deps/json/single_include
rctld_LDFLAGS = $(DC)/build-ios/libdatachannel.a \
                $(DC)/build-ios/deps/libjuice/libjuice.a \
                $(DC)/build-ios/deps/usrsctp/usrsctplib/libusrsctp.a \
                $(MBED)/lib/libmbedtls.a $(MBED)/lib/libmbedx509.a $(MBED)/lib/libmbedcrypto.a \
                -lc++
rctld_FRAMEWORKS = Foundation IOKit
rctld_INSTALL_PATH = /usr/local/bin

include $(THEOS)/makefiles/tool.mk
