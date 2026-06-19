#!/usr/bin/env bash
# Cross-compile libopus for iOS (arm64+arm64e, minos 13.0) -- the audio encoder
# rctld needs to send the iPad's captured PCM as a WebRTC Opus track.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD/.lib/ios"
MIN_IOS=13.0; ARCHS="arm64;arm64e"
mkdir -p "$ROOT"; cd "$ROOT"
[ -d opus ] || git clone --branch v1.5.2 --depth 1 https://github.com/xiph/opus.git
cd opus
cmake -B build-ios -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
  -DCMAKE_INSTALL_PREFIX="$ROOT/opus-install" \
  -DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF
cmake --build build-ios -j && cmake --install build-ios
echo "== libopus =="; find build-ios -name 'libopus.a'; lipo -info "$ROOT/opus-install/lib/libopus.a" 2>/dev/null
