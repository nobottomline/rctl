#!/usr/bin/env bash
# Build/install/remove the diagnostic-only rctlaudioprobe.
#
# Default is status only. Loading the probe into mediaserverd is explicit:
#   scripts/audioprobe.sh status
#   scripts/audioprobe.sh stage
#   scripts/audioprobe.sh once
#   scripts/audioprobe.sh load
#   scripts/audioprobe.sh remove
#
# Do not run `load` while a viewer is connected; restarting mediaserverd can
# disrupt active media paths.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${RCTL_SSH:-greatlove}"
REMOTE_DIR="/Library/MobileSubstrate/DynamicLibraries"
DYLIB="$REMOTE_DIR/rctlaudioprobe.dylib"
PLIST="$REMOTE_DIR/rctlaudioprobe.plist"
LOG="/tmp/rctl-audioprobe.log"
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
    echo '[audioprobe] files:'
    ls -l '$DYLIB' '$PLIST' 2>/dev/null || true
    echo '[audioprobe] staged:'
    ls -l /tmp/rctlaudioprobe.dylib /tmp/rctlaudioprobe.plist 2>/dev/null || true
    echo '[audioprobe] mediaserverd:'
    ps -A | grep ' /usr/sbin/mediaserverd$' || true
    echo '[audioprobe] log:'
    test -e '$LOG' && tail -n 40 '$LOG' || echo '(no log)'
  "
}

stage_probe() {
  make -C "$ROOT/audioprobe"
  local built="$ROOT/audioprobe/.theos/obj/debug/rctlaudioprobe.dylib"
  test -f "$built"
  scp -q "$built" "$HOST:/tmp/rctlaudioprobe.dylib"
  scp -q "$ROOT/audioprobe/rctlaudioprobe.plist" "$HOST:/tmp/rctlaudioprobe.plist"
  echo "[audioprobe] staged in /tmp only"
}

activate_probe() {
  stage_probe
  ssh "$HOST" "set -e
    cp /tmp/rctlaudioprobe.dylib '$DYLIB'
    cp /tmp/rctlaudioprobe.plist '$PLIST'
    ldid -S '$DYLIB'
    chmod 644 '$PLIST'
    echo '[audioprobe] activated in MobileSubstrate path'
  "
}

load_probe() {
  activate_probe
  ssh "$HOST" "set -e
    rm -f '$LOG'
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
        echo \"[audioprobe] mediaserverd restarted pid=\$NOW at \${i}s\"
        break
      fi
    done
    sleep 2
    test -e '$LOG' && tail -n 80 '$LOG' || { echo '[audioprobe] no log produced'; exit 1; }
  "
}

once_probe() {
  load_probe
  remove_probe
}

remove_probe() {
  ssh "$HOST" "set -e
    LINE=\$(ps -A | grep ' /usr/sbin/mediaserverd$' | head -n 1 || true)
    set -- \$LINE
    BEFORE=\${1:-}
    rm -f '$DYLIB' '$PLIST' /tmp/rctlaudioprobe.dylib /tmp/rctlaudioprobe.plist
    killall mediaserverd 2>/dev/null || true
    i=0
    while [ \$i -lt 20 ]; do
      i=\$((i+1)); sleep 1
      LINE=\$(ps -A | grep ' /usr/sbin/mediaserverd$' | head -n 1 || true)
      set -- \$LINE
      NOW=\${1:-}
      if [ -n \"\$NOW\" ] && [ \"\$NOW\" != \"\$BEFORE\" ]; then
        echo \"[audioprobe] removed; clean mediaserverd pid=\$NOW at \${i}s\"
        exit 0
      fi
    done
    echo '[audioprobe] removed; mediaserverd restart not observed'
  "
}

case "$MODE" in
  status) remote_status ;;
  stage) stage_probe; remote_status ;;
  once) once_probe; remote_status ;;
  load) load_probe ;;
  remove) remove_probe; remote_status ;;
esac
