# rctld — root daemon (transport + automation API). Installed to /usr/local/bin,
# launched by /Library/LaunchDaemons/com.greatlove.rctld.plist (shipped via layout/).

TARGET := iphone:clang:14.5:14.0
# Keep the daemon arm64-only. On iOS 14 arm64e devices, the arm64e tool slice
# can hit pointer-auth failures while loading Objective-C metadata from the
# optional relay client. The SpringBoard tweaks still build arm64e separately.
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME = rctld
rctld_FILES = main.mm \
              ../core/net/RelayClient.mm \
              ../core/net/HttpStreamServer.mm \
              ../core/net/Term.mm \
              ../core/ipc/Ipc.c
rctld_CFLAGS = -fobjc-arc -I../core -Wno-deprecated-declarations
rctld_FRAMEWORKS = Foundation IOKit
rctld_INSTALL_PATH = /usr/local/bin

include $(THEOS)/makefiles/tool.mk
