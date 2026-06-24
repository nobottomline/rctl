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
# Usage: scripts/deploy.sh                         (USB tunnel: iproxy 2222:22 8080:8080)
#        RCTL_SSH=greatlove scripts/deploy.sh      (over Wi-Fi)
#        RCTL_DEB=personalized/...+relay.deb scripts/deploy.sh
set -euo pipefail

THEOS="${THEOS:-/Users/grigorij/theos}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${RCTL_SSH:-rctl-device}"        # ~/.ssh/config alias

if [[ -n "${RCTL_DEB:-}" ]]; then
  DEB="$RCTL_DEB"
  case "$DEB" in
    /*) ;;
    *) DEB="$ROOT/$DEB" ;;
  esac
  [[ -f "$DEB" ]] || { echo "[deploy] RCTL_DEB not found: $DEB" >&2; exit 1; }
else
  make -C "$ROOT" THEOS="$THEOS" package
  # sed -n 1p (not head -1) drains ls fully -- head closes the pipe early and,
  # once packages/ holds many .debs, that SIGPIPEs ls and pipefail aborts the deploy.
  DEB="$(ls -t "$ROOT"/packages/*.deb | sed -n '1p')"
fi
echo "[deploy] $DEB -> $HOST"
scp -q "$DEB" "$HOST:/tmp/rctl.deb"

ssh "$HOST" 'bash -s' <<'REMOTE'
set -e
PKG=com.greatlove.rctl
CRDIR=/var/mobile/Library/Logs/CrashReporter
DYLIB=/Library/MobileSubstrate/DynamicLibraries/rctlsbcap.dylib
RELAY_PREF=/var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist
RELAY_PREF_BACKUP=/tmp/com.greatlove.rctl.relay.plist.rctl-preserve

# 1) Remove any existing install (clean respring clears the codesign cache).
if [ -f "$RELAY_PREF" ] && grep -aq "DeviceSecret" "$RELAY_PREF"; then
  cp "$RELAY_PREF" "$RELAY_PREF_BACKUP" 2>/dev/null || true
  chmod 0600 "$RELAY_PREF_BACKUP" 2>/dev/null || true
fi
if dpkg -l | grep -q "$PKG"; then dpkg -r "$PKG" >/dev/null 2>&1 || true; sleep 8; fi

# 2) Fresh install, watched.
# grep -c already prints a clean "0" when nothing matches (and exits 1, which we
# swallow with || true). The old `|| echo 0` APPENDED a second 0 -> "0\n0" ->
# every later `[ "$N" -gt ... ]` died with "integer expression expected".
BEFORE=$(ls "$CRDIR" 2>/dev/null | grep -c SpringBoard || true)
CONN0=$(grep -c "SB connected" /tmp/rctld.log 2>/dev/null || true)
dpkg -i /tmp/rctl.deb 2>&1 | grep -iE "Setting up|error" || true
if [ -f "$RELAY_PREF_BACKUP" ] && grep -aq "DeviceSecret" "$RELAY_PREF_BACKUP"; then
  if [ ! -f "$RELAY_PREF" ] || ! grep -aq "DeviceSecret" "$RELAY_PREF"; then
    cp "$RELAY_PREF_BACKUP" "$RELAY_PREF" 2>/dev/null || true
    chown mobile:mobile "$RELAY_PREF" 2>/dev/null || chown mobile:501 "$RELAY_PREF" 2>/dev/null || true
    chmod 0600 "$RELAY_PREF" 2>/dev/null || true
    launchctl unload /Library/LaunchDaemons/com.greatlove.rctld.plist 2>/dev/null || true
    launchctl load /Library/LaunchDaemons/com.greatlove.rctld.plist 2>/dev/null || true
  fi
fi

i=0
while [ "$i" -lt 30 ]; do
  i=$((i+1)); sleep 1
  NOW=$(ls "$CRDIR" 2>/dev/null | grep -c SpringBoard || true)
  CONN=$(grep -c "SB connected" /tmp/rctld.log 2>/dev/null || true)
  if [ "$NOW" -gt "$BEFORE" ]; then
    # SpringBoard left a fresh crash report: a tweak crash. Disable the dylib and
    # respring so the device comes up clean instead of crash-looping.
    mv "$DYLIB" /tmp/rctlsbcap.crashed.dylib 2>/dev/null || true
    killall -9 SpringBoard 2>/dev/null || true
    echo "DEPLOY=CRASHED — rolled back at ${i}s (dylib disabled)"; exit 1
  fi
  if [ "$CONN" -gt "$CONN0" ]; then echo "DEPLOY=OK — SB connected at ${i}s"; exit 0; fi
done
# No crash AND no fresh "SB connected" line in the window. Usually benign -- the
# tweak reconnected just before our baseline, or the daemon log lagged. Don't cry
# failure: probe real liveness. ps (not pgrep -- absent on this device) + the [X]
# trick so grep doesn't match itself.
if ps -ax | grep -q "[S]pringBoard.app/SpringBoard" && ps -ax | grep -q "[r]ctld"; then
  echo "DEPLOY=OK — SpringBoard + rctld alive after ${i}s (no fresh connect line; benign)"; exit 0
fi
# A render/media wedge (e.g. the daemon thrashing mediaserverd) shows NO crash
# report and a respring can't clear it -- only a userspace reboot can, and that
# kills this SSH session, so leave it to the operator rather than execute blind.
echo "DEPLOY=SUSPECT — SB/rctld not confirmed alive after ${i}s."
echo "  If the screen is black/stuck, recover WITHOUT losing the jailbreak:"
echo "    ssh $HOST 'launchctl reboot userspace'"
exit 2
REMOTE
