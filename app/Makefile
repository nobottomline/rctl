# rctlapp is a small UIKit-process loader. The heavy media payload is a separate
# dylib that this loader never opens in SpringBoard.
include ../mk/native-target.mk
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

LIBCPP := $(shell xcrun --sdk iphoneos --show-sdk-path)/usr/include/c++/v1

TWEAK_NAME = rctlapp
rctlapp_FILES = rctlapp.xm
rctlapp_CFLAGS = -fobjc-arc -I../core -Wno-deprecated-declarations
rctlapp_FRAMEWORKS = UIKit Foundation CoreFoundation AudioToolbox

include $(THEOS)/makefiles/tweak.mk

SUBPROJECTS += media
include $(THEOS)/makefiles/aggregate.mk
