#!/bin/sh
set -eu

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

REPOSITORY="nobottomline/rctl"
DESTINATION="/usr/local/bin/rctl-setup"
VERSION="${RCTL_VERSION:-latest}"

fail() {
  printf 'rctl bootstrap: %s\n' "$*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run through sudo (curl ... | sudo sh)"
command -v curl >/dev/null 2>&1 || fail "curl is required"

case "$(uname -s):$(uname -m)" in
  Linux:x86_64) asset="rctl-setup_linux_amd64" ;;
  Linux:aarch64|Linux:arm64) asset="rctl-setup_linux_arm64" ;;
  *) fail "supported hosts are Linux amd64 and arm64" ;;
esac

case "$VERSION" in
  latest) base="https://github.com/${REPOSITORY}/releases/latest/download" ;;
  *)
    printf '%s\n' "$VERSION" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || \
      fail "RCTL_VERSION must be latest or vMAJOR.MINOR.PATCH"
    base="https://github.com/${REPOSITORY}/releases/download/${VERSION}"
    ;;
esac

umask 077
work="$(mktemp -d "/tmp/rctl-bootstrap.XXXXXX")" || fail "cannot create temporary directory"
candidate=""
cleanup() {
  rm -rf "$work"
  [ -z "$candidate" ] || rm -f "$candidate"
}
trap cleanup 0 HUP INT TERM

download() {
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --retry 3 --connect-timeout 15 --max-time 300 "$1" --output "$2"
}

download "${base}/SHA256SUMS" "$work/SHA256SUMS" || \
  fail "cannot download release checksums (private releases require the documented gh workflow)"
download "${base}/${asset}" "$work/${asset}" || fail "cannot download ${asset}"

expected="$(awk -v name="$asset" '$2 == name { if (found) exit 2; print $1; found=1 } END { if (!found) exit 1 }' "$work/SHA256SUMS")" || \
  fail "release checksum entry is missing or duplicated"
case "$expected" in
  *[!0-9a-f]*|'') fail "release checksum has an invalid format" ;;
esac
[ "${#expected}" -eq 64 ] || fail "release checksum has an invalid length"

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$work/${asset}" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$work/${asset}" | awk '{print $1}')"
else
  fail "sha256sum or shasum is required"
fi
[ "$actual" = "$expected" ] || fail "setup binary checksum mismatch"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh attestation verify "$work/${asset}" --repo "$REPOSITORY" >/dev/null || \
    fail "GitHub build provenance verification failed"
fi

install -d -m 0755 "$(dirname "$DESTINATION")" || fail "cannot create setup binary directory"
candidate="${DESTINATION}.new.$$"
install -m 0755 "$work/${asset}" "$candidate" || fail "cannot install setup binary"
mv -f "$candidate" "$DESTINATION" || fail "cannot activate setup binary"
candidate=""
exec "$DESTINATION" install "$@"
