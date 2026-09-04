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
[[ -f releases.txt && ! -L releases.txt ]] || fail "target release ledger is missing or unsafe"

if grep -Fxq "${TAG}" releases.txt; then
  printf 'APT release already published: %s\n' "${TAG}"
  exit 0
fi

last_tag="$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' releases.txt | tail -n 1)"
[[ "${last_tag}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || \
  fail "target release ledger has no valid final tag"
dpkg --compare-versions "${last_tag#v}" lt "${TAG#v}" || \
  fail "tag ${TAG} does not follow ${last_tag}"

printf '%s\n' "${TAG}" >> releases.txt
git diff --check
git config user.name "rctl release automation"
git config user.email "nobottomline@users.noreply.github.com"
git add releases.txt
git commit --quiet -m "chore: publish ${TAG}"
git push --quiet origin HEAD:main
printf 'APT release ledger updated: %s\n' "${TAG}"
