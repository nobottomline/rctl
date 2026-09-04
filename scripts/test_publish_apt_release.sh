#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rctl-apt-publish-test.XXXXXX")"

cleanup() {
  rm -rf "${WORK}"
}
trap cleanup EXIT

fail() {
  printf 'APT publish test failed: %s\n' "$*" >&2
  exit 1
}

mkdir -p "${WORK}/seed"
cat > "${WORK}/seed/repository.json" <<'JSON'
{"source_repository":"nobottomline/rctl"}
JSON
printf 'v0.3.2\n' > "${WORK}/seed/releases.txt"
git -C "${WORK}/seed" init -q -b main
git -C "${WORK}/seed" config user.name test
git -C "${WORK}/seed" config user.email test@example.invalid
git -C "${WORK}/seed" add repository.json releases.txt
git -C "${WORK}/seed" commit -q -m seed
git clone -q --bare "${WORK}/seed" "${WORK}/remote.git"

RCTL_APT_REPO_REMOTE="${WORK}/remote.git" \
  "${ROOT}/scripts/publish_apt_release.sh" v0.3.3 >/dev/null
git clone -q "${WORK}/remote.git" "${WORK}/result"
grep -Fxq v0.3.3 "${WORK}/result/releases.txt" || fail "new tag was not appended"
[[ "$(grep -Fxc v0.3.3 "${WORK}/result/releases.txt")" == 1 ]] || fail "new tag is duplicated"

RCTL_APT_REPO_REMOTE="${WORK}/remote.git" \
  "${ROOT}/scripts/publish_apt_release.sh" v0.3.3 >/dev/null
rm -rf "${WORK}/result"
git clone -q "${WORK}/remote.git" "${WORK}/result"
[[ "$(grep -Fxc v0.3.3 "${WORK}/result/releases.txt")" == 1 ]] || fail "idempotent publish duplicated the tag"

if RCTL_APT_REPO_REMOTE="${WORK}/remote.git" \
  "${ROOT}/scripts/publish_apt_release.sh" v0.3.1 >/dev/null 2>&1; then
  fail "out-of-order release was accepted"
fi

printf 'APT publish test passed\n'
