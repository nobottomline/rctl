#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEB="${1:-}"
WORK="$(mktemp -d "${TMPDIR:-/private/tmp}/rctl-release-check.XXXXXX")"

cleanup() {
  rm -rf "${WORK}"
}
trap cleanup EXIT

say() {
  printf '==> %s\n' "$*"
}

fail() {
  printf 'release check failed: %s\n' "$*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require dpkg-deb
require git
require nm

if [[ -z "${DEB}" ]]; then
  DEB="$(ls -t "${ROOT}"/packages/*.deb 2>/dev/null | head -1 || true)"
fi

[[ -n "${DEB}" ]] || fail "no .deb found; run make package or pass a .deb path"
[[ -f "${DEB}" ]] || fail "deb not found: ${DEB}"

case "${DEB}" in
  *"/personalized/"*|*"+relay.deb")
    fail "refusing personalized relay package as a public release artifact: ${DEB}"
    ;;
esac

say "checking public package artifact"
dpkg-deb -R "${DEB}" "${WORK}/pkg"

RELAY_PLIST="var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist"
if [[ -e "${WORK}/pkg/${RELAY_PLIST}" ]]; then
  fail "public .deb contains relay config plist: ${RELAY_PLIST}"
fi

if find "${WORK}/pkg/var/mobile/Library/Preferences" -name 'com.greatlove.rctl.relay.plist' -print -quit 2>/dev/null | grep -q .; then
  fail "public .deb contains relay preference plist"
fi

APP_PAYLOAD="Library/MobileSubstrate/DynamicLibraries"
for path in \
  "${APP_PAYLOAD}/rctlapp.dylib" \
  "${APP_PAYLOAD}/rctlapp.plist" \
  "${APP_PAYLOAD}/rctlappmedia.dylib"; do
  [[ -f "${WORK}/pkg/${path}" ]] || fail "public .deb is missing app payload: ${path}"
done
[[ ! -e "${WORK}/pkg/${APP_PAYLOAD}/rctlappmedia.plist" ]] || \
  fail "rctlappmedia must be loaded by rctlapp, not injected by MobileSubstrate"
[[ ! -e "${WORK}/pkg/usr/local/lib/rctl/app/rctlappmedia.dylib" ]] || \
  fail "obsolete app media payload path is present"
grep -q '/Library/MobileSubstrate/DynamicLibraries/rctlappmedia.dylib' \
  "${WORK}/pkg/DEBIAN/postinst" || fail "postinst does not sign rctlappmedia"
strings "${WORK}/pkg/${APP_PAYLOAD}/rctlapp.dylib" | \
  grep -F 'com.greatlove.rctl.vmic.active' >/dev/null || \
  fail "rctlapp has no lazy virtual-mic activation hook"
nm -gU "${WORK}/pkg/${APP_PAYLOAD}/rctlappmedia.dylib" | \
  grep -F '_rctl_virtual_mic_activate' >/dev/null || \
  fail "rctlappmedia has no virtual-mic activation entry point"
if strings "${WORK}/pkg/${APP_PAYLOAD}/rctlappmedia.dylib" | grep -F 'MSHookFunction' >/dev/null; then
  fail "rctlappmedia must not install Substrate hooks from the manually loaded image"
fi
strings "${WORK}/pkg/usr/local/bin/rctld" | \
  grep -F 'jetsam hard limit configured:' >/dev/null || \
  fail "rctld binary has no runtime jetsam limit configuration"

say "checking git-tracked secret paths"
tracked_secret_paths="$(
  git -C "${ROOT}" ls-files \
    '.env' '.env.*' 'relay/.env' 'relay.env' 'personalized/**' \
    '*.secret' '*.token' '*.pem' '*_ed25519' '*_ed25519.pub' \
    'relay-config.plist' '*.p12' '*.mobileprovision'
)"
if [[ -n "${tracked_secret_paths}" ]]; then
  printf '%s\n' "${tracked_secret_paths}" >&2
  fail "secret or personalized paths are tracked by git"
fi

say "checking staged files"
staged_paths="$(git -C "${ROOT}" diff --cached --name-only)"
if printf '%s\n' "${staged_paths}" | grep -E '(^|/)(\.env|relay\.env|relay-config\.plist)$|^personalized/|\.(secret|token|pem|p12|mobileprovision)$|_ed25519(\.pub)?$' >/dev/null; then
  printf '%s\n' "${staged_paths}" >&2
  fail "secret or personalized paths are staged"
fi

say "checking working tree tracked diff for obvious relay secrets"
if git -C "${ROOT}" diff --cached -- . ':(exclude)docs/**' ':(exclude)scripts/smoke_relay.sh' ':(exclude)scripts/release_check.sh' | grep -E 'ENROLL_TOKEN=|DeviceSecret|string>[^<]*(wss://|enroll_|dev_|sess_)' >/dev/null; then
  fail "staged diff contains a value that looks like a relay credential"
fi

say "release check passed: ${DEB}"
