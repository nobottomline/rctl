#!/usr/bin/env bash
# Cross-compile the WebRTC stack (DataChannels + media/RTP tracks) for iOS,
# deployment target 13.0 — the static libs rctld links.
#
# Proven on macOS (Xcode iPhoneOS SDK; built minos 13.0 so it runs on the iPad's
# iOS 14.4 and on iOS 13/15/17). Produces:
#   .lib/ios/mbedtls-install/lib/libmbed{tls,crypto,x509}.a
#   .lib/libdatachannel/build-ios/libdatachannel.a
#   .lib/libdatachannel/build-ios/deps/libjuice/libjuice.a
#   .lib/libdatachannel/build-ios/deps/usrsctp/usrsctplib/libusrsctp.a
#   .lib/libdatachannel/build-ios/deps/libsrtp/libsrtp2.a   (media / RTP tracks)
#
# Requires: Xcode (iphoneos SDK), cmake, ninja. mbedtls codegen also needs the
# Python modules jsonschema + jinja2.
set -euo pipefail
cd "$(dirname "$0")"
SPIKE="$PWD"
ROOT="$SPIKE/.lib/ios"
# Low floor + both arches. We request minos 13.0; the toolchain honours it for the
# arm64 slice (true iOS 13 support on A11-and-older devices) but clamps the arm64e
# slice to 14.0 (arm64e's floor). Net coverage: iOS 13 via arm64, iOS 14+ (incl.
# the A12 iPad Air 3 on 14.4 and future iOS 15/17 phones) via arm64e. Verify with:
#   for a in arm64 arm64e; do lipo <lib> -thin $a -o /tmp/x.a; \
#     otool -l /tmp/x.a | grep -A3 LC_BUILD_VERSION | grep minos | sort -u; done
MIN_IOS=13.0
ARCHS="arm64;arm64e"
mkdir -p "$ROOT"

# ── mbedtls 3.6 (DTLS). DTLS-SRTP must be enabled: libdatachannel's mbedtls path
#    references the SRTP profile symbols, and libsrtp's mbedtls engine needs them. ──
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

# ── libdatachannel WITH media (RTP tracks). NO_MEDIA=0 pulls in the bundled
#    libsrtp2, built with its Mbed TLS crypto engine (USE_MBEDTLS -> ENABLE_MBEDTLS).
#    Cross-compiling, so point CMAKE_FIND_ROOT_PATH at the mbedtls install or
#    find_library/find_package won't see it (libsrtp's mbedtls lookup needs it too).
#    A fresh build dir avoids a stale NO_MEDIA=1 cache that would skip libsrtp. ──
cd "$SPIKE/.lib/libdatachannel"
[ -d include/rtc ] || { echo "clone libdatachannel into .lib first (see README)"; exit 1; }
rm -rf build-ios
cmake -B build-ios -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
  -DBUILD_SHARED_LIBS=OFF \
  -DUSE_MBEDTLS=1 -DUSE_GNUTLS=0 -DUSE_NICE=0 -DNO_MEDIA=0 \
  -DNO_TESTS=1 -DNO_EXAMPLES=1 \
  -DCMAKE_PREFIX_PATH="$MB" -DCMAKE_FIND_ROOT_PATH="$MB" \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH
cmake --build build-ios -j

echo "── iOS arm64 static libs ──"
find build-ios -name '*.a'; ls "$MB"/lib/libmbed*.a
vtool -show-build build-ios/libdatachannel.a 2>/dev/null | grep -iE 'platform|minos|sdk' || true
