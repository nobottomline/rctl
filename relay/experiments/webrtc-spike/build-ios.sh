#!/usr/bin/env bash
# Phase 3 feasibility: cross-compile the WebRTC DataChannel stack for iOS arm64,
# deployment target 14.0 — the static libs rctld will eventually link.
#
# Proven on macOS (Xcode iPhoneOS SDK; built minos 14.0 so it runs on the iPad's
# iOS 14.4). Produces:
#   .lib/ios/mbedtls-install/lib/libmbed{tls,crypto,x509}.a
#   .lib/libdatachannel/build-ios/libdatachannel.a
#   .lib/libdatachannel/build-ios/deps/libjuice/libjuice.a
#   .lib/libdatachannel/build-ios/deps/usrsctp/usrsctplib/libusrsctp.a
#
# Requires: Xcode (iphoneos SDK), cmake, ninja. mbedtls codegen also needs the
# Python modules jsonschema + jinja2.
set -euo pipefail
cd "$(dirname "$0")"
SPIKE="$PWD"
ROOT="$SPIKE/.lib/ios"
# Low floor + both arches: 13.0 covers iOS 13/14/15/17 from the libs' side, and a
# fat arm64+arm64e slice covers the current arm64 iPad and future arm64e phones.
MIN_IOS=13.0
ARCHS="arm64;arm64e"
mkdir -p "$ROOT"

# ── mbedtls 3.6 (DTLS). DTLS-SRTP must be enabled: libdatachannel's mbedtls path
#    references the SRTP profile symbols unconditionally, even with NO_MEDIA. ──
if [ ! -f "$ROOT/mbedtls-install/lib/libmbedtls.a" ]; then
  cd "$ROOT"
  [ -d mbedtls ] || git clone --branch mbedtls-3.6 --depth 1 \
    --recurse-submodules --shallow-submodules https://github.com/Mbed-TLS/mbedtls.git
  cd mbedtls
  python3 -m pip install --break-system-packages -q jsonschema jinja2 || true
  python3 scripts/config.py set MBEDTLS_SSL_DTLS_SRTP
  cmake -B build-ios -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
    -DCMAKE_INSTALL_PREFIX="$ROOT/mbedtls-install" \
    -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DUSE_SHARED_MBEDTLS_LIBRARY=OFF
  cmake --build build-ios -j && cmake --install build-ios
fi
MB="$ROOT/mbedtls-install"

# ── libdatachannel (DataChannels only: NO_MEDIA). Cross-compiling, so point
#    CMAKE_FIND_ROOT_PATH at the mbedtls install or find_library won't see it. ──
cd "$SPIKE/.lib/libdatachannel"
[ -d include/rtc ] || { echo "clone libdatachannel into .lib first (see README)"; exit 1; }
cmake -B build-ios -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
  -DBUILD_SHARED_LIBS=OFF \
  -DUSE_MBEDTLS=1 -DUSE_GNUTLS=0 -DUSE_NICE=0 -DNO_MEDIA=1 \
  -DNO_TESTS=1 -DNO_EXAMPLES=1 \
  -DCMAKE_PREFIX_PATH="$MB" -DCMAKE_FIND_ROOT_PATH="$MB" \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH
cmake --build build-ios -j

echo "── iOS arm64 static libs ──"
find build-ios -name '*.a'; ls "$MB"/lib/libmbed*.a
vtool -show-build build-ios/libdatachannel.a 2>/dev/null | grep -iE 'platform|minos|sdk' || true
