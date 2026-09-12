# Keep all native subprojects on the same SDK and deployment target.
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
TARGET := iphone:clang:15.6:15.0
ADDITIONAL_CFLAGS += -DRCTL_ROOTLESS=1
export THEOS_OBJ_DIR_NAME = obj/rootless$(_THEOS_OBJ_DIR_EXTENSION)
export THEOS_STAGING_DIR_NAME = _rootless
THEOS_PACKAGE_DIR = packages/rootless
else
TARGET := iphone:clang:14.5:14.0
endif
