#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-}"
REMOTE="${RCTL_APT_REPO_REMOTE:-git@github.com:nobottomline/rctl-repo.git}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rctl-apt-publish.XXXXXX")"

cleanup() {
  rm -rf "${WORK}"
}
trap cleanup EXIT

fail() {
  printf 'APT publication failed: %s\n' "$*" >&2
  exit 1
}

[[ "${TAG}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || \
  fail "tag must be vMAJOR.MINOR.PATCH"
command -v dpkg >/dev/null 2>&1 || fail "dpkg is required"
command -v git >/dev/null 2>&1 || fail "git is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"

git clone --quiet --depth=1 "${REMOTE}" "${WORK}/repository"
cd "${WORK}/repository"

[[ "$(jq -r .source_repository repository.json 2>/dev/null)" == "nobottomline/rctl" ]] || \
  fail "target repository has an unexpected source identity"
for ledger in releases.txt rootless-releases.txt; do
  [[ -f "$ledger" && ! -L "$ledger" ]] || fail "target release ledger is missing or unsafe: $ledger"
done

if grep -Fxq "${TAG}" releases.txt && grep -Fxq "${TAG}" rootless-releases.txt; then
  printf 'APT release already published: %s\n' "${TAG}"
  exit 0
fi

last_tag="$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' releases.txt | tail -n 1)"
[[ "${last_tag}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || \
  fail "target release ledger has no valid final tag"
dpkg --compare-versions "${last_tag#v}" le "${TAG#v}" || \
  fail "tag ${TAG} does not follow ${last_tag}"

# Fail before changing either ledger if a lane is missing, private or invalid.
[[ -f scripts/verify-release.sh && ! -L scripts/verify-release.sh ]] || fail "APT release verifier is missing"
bash scripts/verify-release.sh "$TAG" "$WORK/verified" iphoneos-arm iphoneos-arm64

for ledger in releases.txt rootless-releases.txt; do
  if ! grep -Fxq "$TAG" "$ledger"; then
    previous="$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$ledger" | tail -n 1)"
    if [[ -n "$previous" ]]; then
      [[ "$previous" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "invalid ledger tail: $ledger"
      dpkg --compare-versions "${previous#v}" lt "${TAG#v}" || fail "out-of-order tag for $ledger"
    fi
    printf '%s\n' "$TAG" >> "$ledger"
  fi
done
git diff --check
git config user.name "rctl release automation"
git config user.email "nobottomline@users.noreply.github.com"
git add releases.txt rootless-releases.txt
git commit --quiet -m "chore: publish ${TAG}"
git push --quiet origin HEAD:main
printf 'APT release ledgers updated for rootful and rootless: %s\n' "${TAG}"
