#!/usr/bin/env bash
# Build/install/remove the diagnostic-only rctlaudiosource skeleton.
#
# Default is status only. Loading into mediaserverd is explicit:
#   scripts/audiosource.sh status
#   scripts/audiosource.sh stage
#   scripts/audiosource.sh once
#   scripts/audiosource.sh load
#   scripts/audiosource.sh remove
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${RCTL_SSH:-greatlove}"
REMOTE_DIR="/Library/MobileSubstrate/DynamicLibraries"
DYLIB="$REMOTE_DIR/rctlaudiosource.dylib"
PLIST="$REMOTE_DIR/rctlaudiosource.plist"
LOG="/tmp/rctl-audiosource.log"
MARKER="/tmp/rctl-audiosource-tone"
MODE="${1:-status}"

usage() {
  echo "usage: $0 [status|stage|once|load|remove]" >&2
  exit 2
}

case "$MODE" in
  status|stage|once|load|remove) ;;
  *) usage ;;
esac

remote_status() {
  ssh "$HOST" "set -e
    echo '[audiosource] files:'
    ls -l '$DYLIB' '$PLIST' 2>/dev/null || true
    echo '[audiosource] staged:'
    ls -l /tmp/rctlaudiosource.dylib /tmp/rctlaudiosource.plist 2>/dev/null || true
    echo '[audiosource] marker:'
    ls -l '$MARKER' 2>/dev/null || true
    echo '[audiosource] sockets:'
    ls -l /var/run/rctl-audio.sock 2>/dev/null || true
    echo '[audiosource] mediaserverd:'
    ps -A | grep ' /usr/sbin/mediaserverd$' || true
    echo '[audiosource] log:'
    test -e '$LOG' && tail -n 40 '$LOG' || echo '(no log)'
  "
}

stage_source() {
  make -C "$ROOT/audiosource"
  local built="$ROOT/audiosource/.theos/obj/debug/rctlaudiosource.dylib"
  test -f "$built"
  scp -q "$built" "$HOST:/tmp/rctlaudiosource.dylib"
  scp -q "$ROOT/audiosource/rctlaudiosource.plist" "$HOST:/tmp/rctlaudiosource.plist"
  echo "[audiosource] staged in /tmp only"
}

activate_source() {
  stage_source
  ssh "$HOST" "set -e
    cp /tmp/rctlaudiosource.dylib '$DYLIB'
    cp /tmp/rctlaudiosource.plist '$PLIST'
    ldid -S '$DYLIB'
    chmod 644 '$PLIST'
    echo '[audiosource] activated in MobileSubstrate path'
  "
}

load_source() {
  activate_source
  ssh "$HOST" "set -e
    rm -f '$LOG'
    touch '$MARKER'
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
        echo \"[audiosource] mediaserverd restarted pid=\$NOW at \${i}s\"
        break
      fi
    done
    sleep 8
    test -e '$LOG' && tail -n 80 '$LOG' || { echo '[audiosource] no log produced'; exit 1; }
  "
}

remove_source() {
  ssh "$HOST" "set -e
    LINE=\$(ps -A | grep ' /usr/sbin/mediaserverd$' | head -n 1 || true)
    set -- \$LINE
    BEFORE=\${1:-}
    rm -f '$DYLIB' '$PLIST' /tmp/rctlaudiosource.dylib /tmp/rctlaudiosource.plist '$MARKER'
    killall mediaserverd 2>/dev/null || true
    i=0
    while [ \$i -lt 20 ]; do
      i=\$((i+1)); sleep 1
      LINE=\$(ps -A | grep ' /usr/sbin/mediaserverd$' | head -n 1 || true)
      set -- \$LINE
      NOW=\${1:-}
      if [ -n \"\$NOW\" ] && [ \"\$NOW\" != \"\$BEFORE\" ]; then
        echo \"[audiosource] removed; clean mediaserverd pid=\$NOW at \${i}s\"
        exit 0
      fi
    done
    echo '[audiosource] removed; mediaserverd restart not observed'
  "
}

once_source() {
  load_source
  remove_source
}

case "$MODE" in
  status) remote_status ;;
  stage) stage_source; remote_status ;;
  once) once_source; remote_status ;;
  load) load_source ;;
  remove) remove_source; remote_status ;;
esac
