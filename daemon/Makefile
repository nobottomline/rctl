# rctld — root daemon (transport + automation API). Installed to /usr/local/bin,
# launched by /Library/LaunchDaemons/com.greatlove.rctld.plist (shipped via layout/).

TARGET := iphone:clang:14.5:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = rctld
rctld_FILES = main.mm \
              ../core/net/HttpStreamServer.mm \
              ../core/net/Term.mm \
              ../core/ipc/Ipc.c
rctld_CFLAGS = -fobjc-arc -I../core -Wno-deprecated-declarations
rctld_FRAMEWORKS = Foundation
rctld_INSTALL_PATH = /usr/local/bin

include $(THEOS)/makefiles/tool.mk
