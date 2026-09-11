#!/usr/bin/env bash
# Build audited, LAN-only packages; never install or publish them.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scheme=all
version=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scheme|--version)
      [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }
      if [[ $1 == --scheme ]]; then scheme=$2; else version=$2; fi
      shift 2 ;;
    -h|--help)
      echo 'Usage: scripts/build-packages.sh [--scheme all|rootful|rootless] [--version DEBIAN_VERSION]'
      echo 'Without --version, builds a timestamped prerelease from control and Git.'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$scheme" in all|rootful|rootless) ;; *) echo 'invalid package scheme' >&2; exit 2 ;; esac
: "${THEOS:?Set THEOS to your Theos installation}"
if [[ -z "$version" ]]; then
  base="$(awk '/^Version:/{print $2; exit}' "$ROOT/control")"
  revision="$(git -C "$ROOT" rev-parse --short=12 HEAD)"
  version="${base}~test.$(date -u +%Y%m%d%H%M%S).${revision}"
fi
# Version is also a path component and a make variable, not arbitrary input.
[[ "$version" =~ ^[0-9][A-Za-z0-9.+~_-]*$ ]] || { echo 'invalid package version' >&2; exit 2; }
dpkg --validate-version "$version"
for lane in rootful rootless; do
  [[ "$scheme" == all || "$scheme" == "$lane" ]] || continue
  theos_scheme=
  arch=iphoneos-arm
  directory="$ROOT/packages"
  if [[ "$lane" == rootless ]]; then
    theos_scheme=rootless
    arch=iphoneos-arm64
    directory="$directory/rootless"
  fi
  make -C "$ROOT" THEOS_PACKAGE_SCHEME="$theos_scheme" FINALPACKAGE=1 DEBUG=0 \
    PACKAGE_VERSION="$version" package
  deb="$directory/com.greatlove.rctl_${version}_${arch}.deb"
  [[ "$(dpkg-deb -f "$deb" Package)" == com.greatlove.rctl && \
     "$(dpkg-deb -f "$deb" Version)" == "$version" && \
     "$(dpkg-deb -f "$deb" Architecture)" == "$arch" ]] || {
    echo 'built package metadata does not match requested lane/version' >&2; exit 1;
  }
  "$ROOT/scripts/release_check.sh" "$deb"
  printf '\nAudited %s package (runtime qualification separate): %s\n' "$lane" "$deb"
done
