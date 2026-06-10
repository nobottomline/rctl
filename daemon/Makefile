# rctld — root daemon (transport + automation API). Installed to /usr/local/bin,
# launched by /Library/LaunchDaemons/com.greatlove.rctld.plist (shipped via layout/).

TARGET := iphone:clang:14.5:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = rctld rctlcam
rctld_FILES = main.mm \
              ../core/net/HttpStreamServer.mm \
              ../core/ipc/Ipc.c
rctld_CFLAGS = -fobjc-arc -I../core -Wno-deprecated-declarations
rctld_FRAMEWORKS = Foundation
rctld_INSTALL_PATH = /usr/local/bin

# Isolated camera helper: links AVFoundation (no header import) and embeds an
# Info.plist carrying NSCameraUsageDescription so the camera privacy check passes.
rctlcam_FILES = rctlcam.mm
rctlcam_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
rctlcam_LDFLAGS = -Wl,-sectcreate,__TEXT,__info_plist,$(THEOS_PROJECT_DIR)/daemon/cam-Info.plist
rctlcam_FRAMEWORKS = Foundation AVFoundation
rctlcam_INSTALL_PATH = /usr/local/bin

include $(THEOS)/makefiles/tool.mk
