#!/usr/bin/env bash
# Safe deploy: build the .deb, then REMOVE + FRESH INSTALL on the device.
#
# Why not `make package install`? Upgrading the dylib in place over a running
# SpringBoard leaves a stale code-signing state — the kernel keeps the old file's
# page hashes, so the freshly re-signed __TEXT comes up non-executable and
# SpringBoard SIGBUS-crashes at load (and can crash-loop into Substitute safe
# mode). A clean `dpkg -r` (respring with no tweak) before `dpkg -i` avoids it.
#
# Installs under a watchdog: if SpringBoard crashes after install, the dylib is
# moved aside and SpringBoard resprung immediately, so one bad build can't loop
# the device into safe mode.
#
# Usage: scripts/deploy.sh            (USB tunnel: iproxy 2222:22 8080:8080)
#        RCTL_SSH=greatlove scripts/deploy.sh   (over Wi-Fi)
set -euo pipefail

THEOS="${THEOS:-/Users/grigorij/theos}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${RCTL_SSH:-rctl-device}"        # ~/.ssh/config alias

make -C "$ROOT" THEOS="$THEOS" package
DEB="$(ls -t "$ROOT"/packages/*.deb | head -1)"
echo "[deploy] $DEB -> $HOST"
scp -q "$DEB" "$HOST:/tmp/rctl.deb"

ssh "$HOST" 'bash -s' <<'REMOTE'
set -e
PKG=com.greatlove.rctl
CRDIR=/var/mobile/Library/Logs/CrashReporter
DYLIB=/Library/MobileSubstrate/DynamicLibraries/rctlsbcap.dylib

# 1) Remove any existing install (clean respring clears the codesign cache).
if dpkg -l | grep -q "$PKG"; then dpkg -r "$PKG" >/dev/null 2>&1 || true; sleep 8; fi

# 2) Fresh install, watched.
BEFORE=$(ls "$CRDIR" 2>/dev/null | grep -c SpringBoard || echo 0)
CONN0=$(grep -c "SB connected" /tmp/rctld.log 2>/dev/null || echo 0)
dpkg -i /tmp/rctl.deb 2>&1 | grep -iE "Setting up|error" || true

i=0
while [ $i -lt 20 ]; do
  i=$((i+1)); sleep 1
  NOW=$(ls "$CRDIR" 2>/dev/null | grep -c SpringBoard || echo 0)
  CONN=$(grep -c "SB connected" /tmp/rctld.log 2>/dev/null || echo 0)
  if [ "$NOW" -gt "$BEFORE" ]; then
    mv "$DYLIB" /tmp/rctlsbcap.crashed.dylib 2>/dev/null || true
    killall -9 SpringBoard 2>/dev/null || true
    echo "DEPLOY=CRASHED — rolled back at ${i}s (dylib disabled)"; exit 1
  fi
  if [ "$CONN" -gt "$CONN0" ]; then echo "DEPLOY=OK — SB connected at ${i}s"; exit 0; fi
done
echo "DEPLOY=TIMEOUT — no crash but SB did not connect"; exit 2
REMOTE
