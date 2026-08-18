TARGET := iphone:clang:14.5:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

LIBCPP := $(shell xcrun --sdk iphoneos --show-sdk-path)/usr/include/c++/v1

LIBRARY_NAME = rctlappmedia
rctlappmedia_FILES = ../MediaAgent.mm ../CameraAgent.mm ../VirtualMicClient.mm \
                     ../../core/audio/VirtualMicDSP.cpp ../../core/encode/H264Encoder.mm
rctlappmedia_CFLAGS = -fobjc-arc -I.. -I../../core -Wno-deprecated-declarations
rctlappmedia_CCFLAGS = -std=gnu++17 -isystem $(LIBCPP)
rctlappmedia_FRAMEWORKS = UIKit Foundation CoreFoundation AudioToolbox AVFoundation \
                          VideoToolbox CoreMedia CoreVideo IOSurface
rctlappmedia_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
rctlappmedia_INSTALL = 0

include $(THEOS)/makefiles/library.mk
