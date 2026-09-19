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
printf '# Rootless releases\n' > "${WORK}/seed/rootless-releases.txt"
mkdir -p "${WORK}/seed/scripts"
cat > "${WORK}/seed/scripts/verify-release.sh" <<'SH'
set -eu
test "$3" = iphoneos-arm
test "$4" = iphoneos-arm64
test "${APT_TEST_VERIFY_FAIL:-0}" = 0
mkdir "$2"
SH
git -C "${WORK}/seed" init -q -b main
git -C "${WORK}/seed" config user.name test
git -C "${WORK}/seed" config user.email test@example.invalid
git -C "${WORK}/seed" add repository.json releases.txt rootless-releases.txt scripts
git -C "${WORK}/seed" commit -q -m seed
git clone -q --bare "${WORK}/seed" "${WORK}/remote.git"

RCTL_APT_REPO_REMOTE="${WORK}/remote.git" \
  "${ROOT}/scripts/publish_apt_release.sh" v0.3.3 >/dev/null
git clone -q "${WORK}/remote.git" "${WORK}/result"
grep -Fxq v0.3.3 "${WORK}/result/releases.txt" || fail "new tag was not appended"
[[ "$(grep -Fxc v0.3.3 "${WORK}/result/releases.txt")" == 1 ]] || fail "new tag is duplicated"
[[ "$(grep -Fxc v0.3.3 "${WORK}/result/rootless-releases.txt")" == 1 ]] || fail "rootless tag is missing or duplicated"

RCTL_APT_REPO_REMOTE="${WORK}/remote.git" \
  "${ROOT}/scripts/publish_apt_release.sh" v0.3.3 >/dev/null
rm -rf "${WORK}/result"
git clone -q "${WORK}/remote.git" "${WORK}/result"
[[ "$(grep -Fxc v0.3.3 "${WORK}/result/releases.txt")" == 1 ]] || fail "idempotent publish duplicated the tag"
[[ "$(grep -Fxc v0.3.3 "${WORK}/result/rootless-releases.txt")" == 1 ]] || fail "idempotent publish duplicated rootless"

before="$(git --git-dir="$WORK/remote.git" rev-parse main)"
if APT_TEST_VERIFY_FAIL=1 RCTL_APT_REPO_REMOTE="$WORK/remote.git" \
  "$ROOT/scripts/publish_apt_release.sh" v0.3.4 >/dev/null 2>&1; then
  fail "failed artifact validation was accepted"
fi
[[ "$(git --git-dir="$WORK/remote.git" rev-parse main)" == "$before" ]] || fail "failed validation changed the remote"

# Recover an interrupted older publisher that updated only the rootful ledger.
git -C "$WORK/result" config user.name test
git -C "$WORK/result" config user.email test@example.invalid
printf 'v0.3.4\n' >> "$WORK/result/releases.txt"
git -C "$WORK/result" add releases.txt
git -C "$WORK/result" commit -q -m 'rootful only'
git -C "$WORK/result" push -q origin main
RCTL_APT_REPO_REMOTE="$WORK/remote.git" "$ROOT/scripts/publish_apt_release.sh" v0.3.4 >/dev/null
git -C "$WORK/result" pull -q --ff-only
[[ "$(grep -Fxc v0.3.4 "$WORK/result/rootless-releases.txt")" == 1 ]] || fail "rootless backfill failed"

if RCTL_APT_REPO_REMOTE="${WORK}/remote.git" \
  "${ROOT}/scripts/publish_apt_release.sh" v0.3.1 >/dev/null 2>&1; then
  fail "out-of-order release was accepted"
fi

printf 'APT publish test passed\n'
