# rctl — aggregate project. Builds every component into one Debian package:
#   springboard/  -> rctlsbcap.dylib  (thin SpringBoard agent: capture/encode/inject)
#   daemon/       -> rctld            (root daemon: transport + automation API)   [added in P2.5b]
#   app/          -> rctlapp.dylib    (app-side media agent: camera + mic)
#   audio/        -> rctlaudio.dylib  (inactive mediaserverd audio payload)
# Extra payload (web client, LaunchDaemon plist) ships via layout/.
#
#   make deps              build the pinned iOS WebRTC static libs (run once, first)
#   make package           build the .deb into ./packages/
#   make package-relay     build a private relay-enabled .deb into ./personalized/
#   make package install   ... and install it over SSH (USB tunnel: see below)
#
# Install over the USB tunnel (iproxy 2222:22):
#   THEOS_DEVICE_IP=localhost THEOS_DEVICE_PORT=2222 make package install

export ARCHS = arm64 arm64e
export TARGET = iphone:clang:14.5:14.0

# IMPORTANT: deploy with scripts/deploy.sh (remove + fresh install), NOT
# `make package install`. Upgrading the dylib in place over a running SpringBoard
# leaves a stale code-signing state (__TEXT becomes non-executable) and crashes
# SpringBoard at load; a clean remove + fresh install avoids it.

# Default install target = the USB tunnel (see ~/.ssh/config Host rctl-device).
# Override for Wi-Fi: THEOS_DEVICE_IP=greatlove THEOS_DEVICE_PORT=22 make package install
export THEOS_DEVICE_IP ?= rctl-device
export THEOS_DEVICE_PORT ?= 2222

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += springboard
SUBPROJECTS += daemon
SUBPROJECTS += app

include $(THEOS)/makefiles/aggregate.mk

# Stage the React/Vite control client (web/) as the device control page.
# It's one self-contained index.html (xterm etc. inlined), rebuilt only when its
# sources changed. The old vanilla page is kept under web/legacy/ for reference.
after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/var/mobile/rctl"$(ECHO_END)
	$(ECHO_NOTHING)if [ ! -f web/dist/index.html ] || find web/src web/index.html web/package.json -newer web/dist/index.html 2>/dev/null | grep -q .; then echo "==> Building web client"; ( cd web && { [ -d node_modules ] || npm ci; } && npm run build ); fi$(ECHO_END)
	$(ECHO_NOTHING)cp web/dist/index.html "$(THEOS_STAGING_DIR)/var/mobile/rctl/index.html"$(ECHO_END)
	$(ECHO_NOTHING)$(MAKE) -C audio$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/usr/local/lib/rctl/audio"$(ECHO_END)
	$(ECHO_NOTHING)set -e; dylib=".theos/obj/debug/rctlaudio.dylib"; [ -f "$$dylib" ] || dylib="audio/.theos/obj/debug/rctlaudio.dylib"; cp "$$dylib" "$(THEOS_STAGING_DIR)/usr/local/lib/rctl/audio/rctlaudio.dylib"$(ECHO_END)
	$(ECHO_NOTHING)cp audio/rctlaudio.plist "$(THEOS_STAGING_DIR)/usr/local/lib/rctl/audio/rctlaudio.plist"$(ECHO_END)

.PHONY: package-relay
package-relay: package
	@echo "==> Personalizing latest .deb with relay.env"
	@scripts/personalize_deb.sh

.PHONY: smoke-relay
smoke-relay:
	@scripts/smoke_relay.sh

.PHONY: release-check
release-check:
	@scripts/release_check.sh

.PHONY: test-personalize
test-personalize:
	@scripts/test_personalize_deb.sh

.PHONY: deps
deps:
	@third_party/webrtc/build-ios.sh
