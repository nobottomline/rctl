#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${THEOS:?Set THEOS to your Theos installation}"
VERSION="$(awk '/^Version:/{print $2; exit}' "$ROOT/control")"
make -C "$ROOT" THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=0 DEBUG=0 \
  PACKAGE_VERSION="${VERSION}~rootless3" package
DEB="$ROOT/packages/rootless/com.greatlove.rctl_${VERSION}~rootless3_iphoneos-arm64.deb"
"$ROOT/scripts/release_check.sh" "$DEB"
printf '\nRootless test package (not device-qualified): %s\n' "$DEB"
