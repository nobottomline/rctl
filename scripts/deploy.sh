#!/usr/bin/env bash
# Build rctld, deploy to the jailbroken iPad, re-sign on-device, optionally run.
#
# The macOS ldid signature is NOT accepted by on-device AMFI, so after scp we
# must re-sign with the device's own ldid or the binary is SIGKILLed at launch.
#
# Usage:
#   scripts/deploy.sh                 # build + deploy + re-sign
#   scripts/deploy.sh run [args...]   # ... then run `rctld args` on the device
set -euo pipefail

THEOS="${THEOS:-/Users/grigorij/theos}"
HOST="${RCTL_HOST:-greatlove}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

make -C "$ROOT/daemon" THEOS="$THEOS"
scp -q "$ROOT/daemon/.theos/obj/debug/rctld" "$HOST:/usr/local/bin/rctld"
ssh "$HOST" 'ldid -S /usr/local/bin/rctld'
echo "[deploy] rctld deployed and re-signed on $HOST"

if [ "${1:-}" = "run" ]; then
  shift
  ssh "$HOST" "/usr/local/bin/rctld $*"
fi
