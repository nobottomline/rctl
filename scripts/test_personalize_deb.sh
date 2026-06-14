#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rctl-personalize-test.XXXXXX")"

cleanup() {
  rm -rf "${WORK}"
}
trap cleanup EXIT

say() {
  printf '==> %s\n' "$*"
}

fail() {
  printf 'personalize test failed: %s\n' "$*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require dpkg-deb

BASE="${WORK}/base"
OUT="${WORK}/out"
EXTRACTED="${WORK}/extracted"
BASE_DEB="${WORK}/com.greatlove.rctl_0.0.0-test_iphoneos-arm.deb"
TOKEN="enroll_test_1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJK"
RELAY_URL="wss://rctl.example.test/device?name=ipad&mode=relay"
DEVICE_NAME="iPad <Air> & Friends"
PLIST="var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist"

say "building minimal public deb fixture"
mkdir -p "${BASE}/DEBIAN" "${BASE}/var/mobile/rctl"
cat >"${BASE}/DEBIAN/control" <<'CONTROL'
Package: com.greatlove.rctl
Name: rctl
Version: 0.0.0-test
Architecture: iphoneos-arm
Maintainer: GreatLove
Description: test fixture
CONTROL
printf 'fixture\n' >"${BASE}/var/mobile/rctl/index.html"
dpkg-deb -b "${BASE}" "${BASE_DEB}" >/dev/null

say "verifying public fixture has no relay config"
dpkg-deb -R "${BASE_DEB}" "${WORK}/public"
if [[ -e "${WORK}/public/${PLIST}" ]]; then
  fail "public fixture unexpectedly contains relay config"
fi

say "personalizing deb"
generated="$(
  RELAY_URL="${RELAY_URL}" \
  ENROLL_TOKEN="${TOKEN}" \
  DEVICE_NAME="${DEVICE_NAME}" \
  OUT_DIR="${OUT}" \
  "${ROOT}/scripts/personalize_deb.sh" "${BASE_DEB}"
)"

[[ -f "${generated}" ]] || fail "personalized deb was not created"
case "${generated}" in
  "${OUT}"/*+relay.deb) ;;
  *) fail "unexpected personalized deb path: ${generated}" ;;
esac

say "checking personalized relay config"
dpkg-deb -R "${generated}" "${EXTRACTED}"
[[ -f "${EXTRACTED}/${PLIST}" ]] || fail "personalized deb missing relay config"

grep -F '<key>Enabled</key>' "${EXTRACTED}/${PLIST}" >/dev/null || fail "Enabled key missing"
grep -F '<true/>' "${EXTRACTED}/${PLIST}" >/dev/null || fail "Enabled=true missing"
grep -F '<string>wss://rctl.example.test/device?name=ipad&amp;mode=relay</string>' "${EXTRACTED}/${PLIST}" >/dev/null || fail "RelayURL was not XML-escaped"
grep -F "<string>${TOKEN}</string>" "${EXTRACTED}/${PLIST}" >/dev/null || fail "EnrollToken missing"
grep -F '<string>iPad &lt;Air&gt; &amp; Friends</string>' "${EXTRACTED}/${PLIST}" >/dev/null || fail "DeviceName was not XML-escaped"

mode="$(stat -f '%Lp' "${EXTRACTED}/${PLIST}" 2>/dev/null || stat -c '%a' "${EXTRACTED}/${PLIST}")"
[[ "${mode}" == "644" ]] || fail "relay config mode should be 644, got ${mode}"

say "checking public release gate rejects personalized deb"
if "${ROOT}/scripts/release_check.sh" "${generated}" >/dev/null 2>&1; then
  fail "release_check accepted personalized relay deb"
fi

say "personalize deb test passed"
