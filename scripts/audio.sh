#!/usr/bin/env bash
# Build/install/remove the mediaserverd rctlaudio agent.
#
# Default is status only. Loading into mediaserverd is explicit:
#   scripts/audio.sh status
#   scripts/audio.sh stage
#   scripts/audio.sh once
#   scripts/audio.sh load
#   scripts/audio.sh capture-load
#   scripts/audio.sh capture-once
#   scripts/audio.sh remove
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${RCTL_SSH:-greatlove}"
REMOTE_DIR="/Library/MobileSubstrate/DynamicLibraries"
DYLIB="$REMOTE_DIR/rctlaudio.dylib"
PLIST="$REMOTE_DIR/rctlaudio.plist"
LOG="/tmp/rctl-audio.log"
MARKER="/tmp/rctl-audio-tone"
CAPTURE_MARKER="/tmp/rctl-audio-capture"
MODE="${1:-status}"

usage() {
  echo "usage: $0 [status|stage|once|load|capture-load|capture-once|remove]" >&2
  exit 2
}

case "$MODE" in
  status|stage|once|load|capture-load|capture-once|remove) ;;
  *) usage ;;
esac

remote_status() {
  ssh "$HOST" "set -e
    echo '[audio] files:'
    ls -l '$DYLIB' '$PLIST' 2>/dev/null || true
    echo '[audio] staged:'
    ls -l /tmp/rctlaudio.dylib /tmp/rctlaudio.plist 2>/dev/null || true
    echo '[audio] marker:'
    ls -l '$MARKER' '$CAPTURE_MARKER' 2>/dev/null || true
    echo '[audio] sockets:'
    ls -l /var/run/rctl-audio.sock 2>/dev/null || true
    echo '[audio] mediaserverd:'
    ps -A | grep ' /usr/sbin/mediaserverd$' || true
    echo '[audio] log:'
    test -e '$LOG' && tail -n 40 '$LOG' || echo '(no log)'
  "
}

stage_source() {
  make -C "$ROOT/audio"
  local built="$ROOT/audio/.theos/obj/debug/rctlaudio.dylib"
  test -f "$built"
  scp -q "$built" "$HOST:/tmp/rctlaudio.dylib"
  scp -q "$ROOT/audio/rctlaudio.plist" "$HOST:/tmp/rctlaudio.plist"
  echo "[audio] staged in /tmp only"
}

activate_source() {
  stage_source
  ssh "$HOST" "set -e
    cp /tmp/rctlaudio.dylib '$DYLIB'
    cp /tmp/rctlaudio.plist '$PLIST'
    ldid -S '$DYLIB'
    chmod 644 '$PLIST'
    echo '[audio] activated in MobileSubstrate path'
  "
}

load_source_with_marker() {
  local marker="$1"
  local wait_secs="$2"
  activate_source
  ssh "$HOST" "set -e
    rm -f '$LOG'
    rm -f '$MARKER' '$CAPTURE_MARKER'
    touch '$marker'
    LINE=\$(ps -A | grep ' /usr/sbin/mediaserverd$' | head -n 1 || true)
    set -- \$LINE
    BEFORE=\${1:-}
    killall mediaserverd 2>/dev/null || true
    i=0
    while [ \$i -lt 20 ]; do
      i=\$((i+1)); sleep 1
      LINE=\$(ps -A | grep ' /usr/sbin/mediaserverd$' | head -n 1 || true)
      set -- \$LINE
      NOW=\${1:-}
      if [ -n \"\$NOW\" ] && [ \"\$NOW\" != \"\$BEFORE\" ]; then
        echo \"[audio] mediaserverd restarted pid=\$NOW at \${i}s\"
        break
      fi
    done
    sleep '$wait_secs'
    test -e '$LOG' && tail -n 80 '$LOG' || { echo '[audio] no log produced'; exit 1; }
  "
}

load_source() {
  load_source_with_marker "$MARKER" 8
}

load_capture_source() {
  load_source_with_marker "$CAPTURE_MARKER" 18
}

remove_source() {
  ssh "$HOST" "set -e
    LINE=\$(ps -A | grep ' /usr/sbin/mediaserverd$' | head -n 1 || true)
    set -- \$LINE
    BEFORE=\${1:-}
    rm -f '$DYLIB' '$PLIST' /tmp/rctlaudio.dylib /tmp/rctlaudio.plist '$MARKER' '$CAPTURE_MARKER'
    killall mediaserverd 2>/dev/null || true
    i=0
    while [ \$i -lt 20 ]; do
      i=\$((i+1)); sleep 1
      LINE=\$(ps -A | grep ' /usr/sbin/mediaserverd$' | head -n 1 || true)
      set -- \$LINE
      NOW=\${1:-}
      if [ -n \"\$NOW\" ] && [ \"\$NOW\" != \"\$BEFORE\" ]; then
        echo \"[audio] removed; clean mediaserverd pid=\$NOW at \${i}s\"
        exit 0
      fi
    done
    echo '[audio] removed; mediaserverd restart not observed'
  "
}

once_source() {
  load_source
  remove_source
}

capture_once_source() {
  load_capture_source
  remove_source
}

case "$MODE" in
  status) remote_status ;;
  stage) stage_source; remote_status ;;
  once) once_source; remote_status ;;
  load) load_source ;;
  capture-load) load_capture_source ;;
  capture-once) capture_once_source; remote_status ;;
  remove) remove_source; remote_status ;;
esac
