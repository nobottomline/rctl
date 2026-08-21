#!/bin/sh
set -eu

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

REPOSITORY="nobottomline/rctl"
DESTINATION="/usr/local/bin/rctl-setup"
VERSION="${RCTL_VERSION:-latest}"
ASSETS_DIR="${RCTL_ASSETS_DIR:-}"

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

if [ -n "$ASSETS_DIR" ]; then
  case "$ASSETS_DIR" in
    /*) ;;
    *) fail "RCTL_ASSETS_DIR must be an absolute path" ;;
  esac
  [ -d "$ASSETS_DIR" ] && [ ! -L "$ASSETS_DIR" ] || \
    fail "RCTL_ASSETS_DIR must be a real directory, not a symlink"
fi

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

fetch_asset() {
  name="$1"
  destination="$2"
  if [ -n "$ASSETS_DIR" ]; then
    source="${ASSETS_DIR}/${name}"
    [ -f "$source" ] && [ ! -L "$source" ] || fail "local release asset is missing or unsafe: ${name}"
    install -m 0600 "$source" "$destination" || fail "cannot stage local release asset ${name}"
  else
    download "${base}/${name}" "$destination" || fail "cannot download ${name}"
  fi
}

fetch_asset "SHA256SUMS" "$work/SHA256SUMS"

package_asset="$(awk '$2 ~ /^rctl_[0-9]+\.[0-9]+\.[0-9]+_iphoneos-arm\.deb$/ { if (found) exit 2; print $2; found=1 } END { if (!found) exit 1 }' "$work/SHA256SUMS")" || \
  fail "release must contain exactly one public rctl device package"

verify_asset() {
  name="$1"
  expected="$(awk -v name="$name" '$2 == name { if (found) exit 2; print $1; found=1 } END { if (!found) exit 1 }' "$work/SHA256SUMS")" || \
    fail "checksum entry for ${name} is missing or duplicated"
  case "$expected" in
    *[!0-9a-f]*|'') fail "checksum for ${name} has an invalid format" ;;
  esac
  [ "${#expected}" -eq 64 ] || fail "checksum for ${name} has an invalid length"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$work/${name}" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$work/${name}" | awk '{print $1}')"
  else
    fail "sha256sum or shasum is required"
  fi
  [ "$actual" = "$expected" ] || fail "checksum mismatch for ${name}"
}

for name in "$asset" "$package_asset"; do
  fetch_asset "$name" "$work/${name}"
  verify_asset "$name"
done

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  for name in "$asset" "$package_asset"; do
    gh attestation verify "$work/${name}" --repo "$REPOSITORY" >/dev/null || \
      fail "GitHub build provenance verification failed for ${name}"
  done
fi

install -d -m 0755 "$(dirname "$DESTINATION")" || fail "cannot create setup binary directory"
[ ! -L "$DESTINATION" ] || fail "refusing to replace a symlink at ${DESTINATION}"
if [ -e "$DESTINATION" ]; then
  [ -f "$DESTINATION" ] || fail "existing ${DESTINATION} is not a regular file"
fi
candidate="${DESTINATION}.new.$$"
install -m 0755 "$work/${asset}" "$candidate" || fail "cannot install setup binary"
if [ -e /var/lib/rctl/setup/ownership.json ]; then
  "$candidate" upgrade "$@" --public-package "$work/$package_asset" || \
    fail "upgrade failed; the previous setup binary remains active"
else
  "$candidate" install "$@" --public-package "$work/$package_asset" || \
    fail "installation failed; no setup binary was activated"
fi

for argument do
  if [ "$argument" = "--dry-run" ]; then
    exit 0
  fi
done
mv -f "$candidate" "$DESTINATION" || fail "lifecycle succeeded but the setup binary could not be activated"
candidate=""
