#!/usr/bin/env bash
# Cross-compile the WebRTC stack rctld links — libdatachannel (DataChannels +
# media/RTP tracks), its DTLS engine (Mbed TLS), and the Opus audio codec — for
# iOS. Reproducible: every dependency is pinned below and fetched from upstream,
# so a fresh clone builds the exact same static libs the daemon is tested against.
#
# Run it via `make deps` from the repo root, or directly. Re-running is cheap:
# already-built dependencies are skipped; only libdatachannel is rebuilt (fast).
#
# Output consumed by daemon/Makefile (all under .lib/, which is gitignored):
#   .lib/libdatachannel/build-ios/libdatachannel.a
#   .lib/libdatachannel/build-ios/deps/libsrtp/libsrtp2.a        (media / RTP)
#   .lib/libdatachannel/build-ios/deps/libjuice/libjuice.a       (ICE)
#   .lib/libdatachannel/build-ios/deps/usrsctp/usrsctplib/libusrsctp.a  (SCTP)
#   .lib/ios/mbedtls-install/lib/libmbed{tls,x509,crypto}.a      (DTLS / DTLS-SRTP)
#   .lib/ios/opus-install/lib/libopus.a                          (audio)
#
# Requires: Xcode (iphoneos SDK), cmake, ninja. mbedtls codegen also needs the
# Python modules jsonschema + jinja2.
set -euo pipefail
cd "$(dirname "$0")"
WEBRTC="$PWD"
LIB="$WEBRTC/.lib"
IOS="$LIB/ios"

# ── pinned versions ─────────────────────────────────────────────────────────
# libdatachannel has no release with the media+mbedtls fixes we rely on, so we
# pin an exact master commit; mbedtls and opus are pinned to exact release tags.
LIBDATACHANNEL_REPO=https://github.com/paullouisageneau/libdatachannel.git
LIBDATACHANNEL_REF=a542d8703bfab42a5533852e18d6d1879e01080a
MBEDTLS_REF=mbedtls-3.6.6
OPUS_REF=v1.5.2

# ── target: low floor, both arches ──────────────────────────────────────────
# We request minos 13.0; the toolchain honours it for the arm64 slice (true iOS
# 13 on A11-and-older) but clamps arm64e to 14.0 (arm64e's floor). Net coverage:
# iOS 13 via arm64, iOS 14+ (incl. the A12 iPad Air 3 on 14.4) via arm64e.
MIN_IOS=13.0
ARCHS="arm64;arm64e"
mkdir -p "$IOS"

# ── 1. Mbed TLS (DTLS). DTLS-SRTP must be enabled: libdatachannel's mbedtls path
#       references the SRTP profile symbols, and libsrtp's mbedtls engine needs
#       them. ────────────────────────────────────────────────────────────────
if [ ! -f "$IOS/mbedtls-install/lib/libmbedtls.a" ]; then
  cd "$IOS"
  [ -d mbedtls ] || git clone --branch "$MBEDTLS_REF" --depth 1 \
    --recurse-submodules --shallow-submodules https://github.com/Mbed-TLS/mbedtls.git
  cd mbedtls
  python3 -m pip install --break-system-packages -q jsonschema jinja2 || true
  python3 scripts/config.py set MBEDTLS_SSL_DTLS_SRTP
  cmake -B build-ios -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
    -DCMAKE_INSTALL_PREFIX="$IOS/mbedtls-install" \
    -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DUSE_SHARED_MBEDTLS_LIBRARY=OFF
  cmake --build build-ios -j && cmake --install build-ios
fi
MB="$IOS/mbedtls-install"

# ── 2. libopus (audio): the encoder rctld uses to send captured PCM as a WebRTC
#       Opus track. ──────────────────────────────────────────────────────────
if [ ! -f "$IOS/opus-install/lib/libopus.a" ]; then
  cd "$IOS"
  [ -d opus ] || git clone --branch "$OPUS_REF" --depth 1 https://github.com/xiph/opus.git
  cd opus
  cmake -B build-ios -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
    -DCMAKE_INSTALL_PREFIX="$IOS/opus-install" \
    -DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF
  cmake --build build-ios -j && cmake --install build-ios
fi

# ── 3. libdatachannel WITH media (RTP tracks). NO_MEDIA=0 pulls in the bundled
#       libsrtp2, built with its Mbed TLS crypto engine. Point CMAKE_FIND_ROOT_PATH
#       at the mbedtls install or find_package won't see it while cross-compiling.
#       A fresh build dir avoids a stale NO_MEDIA=1 cache that would skip libsrtp.
if [ ! -d "$LIB/libdatachannel/include/rtc" ]; then
  mkdir -p "$LIB/libdatachannel"
  cd "$LIB/libdatachannel"
  # Shallow-fetch the exact pinned commit (GitHub allows reachable-SHA fetches).
  git init -q
  git remote add origin "$LIBDATACHANNEL_REPO" 2>/dev/null || true
  git fetch -q --depth 1 origin "$LIBDATACHANNEL_REF"
  git checkout -q FETCH_HEAD
  git submodule update -q --init --recursive --depth 1
fi
cd "$LIB/libdatachannel"
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

echo "── iOS arm64/arm64e static libs ready ──"
find build-ios -name '*.a'
ls "$MB"/lib/libmbed*.a "$IOS"/opus-install/lib/libopus.a
