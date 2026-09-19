#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s /absolute/path/to/tailnet-probe\n' "$0" >&2
    exit 2
fi
case "$1" in /*) ;; *) echo 'Output path must be absolute' >&2; exit 2 ;; esac
cd "$(dirname "$0")"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
clang=$(xcrun --sdk iphoneos --find clang)
GOTOOLCHAIN=go1.26.6 CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$clang" \
    CGO_CFLAGS="-isysroot $sdk -miphoneos-version-min=15.0" \
    CGO_LDFLAGS="-isysroot $sdk -miphoneos-version-min=15.0" \
    go build -trimpath -o "$1" .
ldid -S "$1"
printf 'Built diagnostic-only iOS 15+ executable: %s\n' "$1"
