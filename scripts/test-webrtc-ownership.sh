#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
dc=third_party/webrtc/.lib/libdatachannel
[[ -f "$dc/CMakeLists.txt" ]] || { echo "Run make deps first" >&2; exit 1; }
build=$(mktemp -d "${TMPDIR:-/tmp}/rctl-webrtc-ownership.XXXXXX")
trap 'rm -rf "$build"' EXIT
# Native macOS qualification uses the pinned source, without touching iOS libs.
cmake -S "$dc" -B "$build" -DNO_TESTS=ON -DNO_EXAMPLES=ON -DNO_WEBSOCKET=ON \
    -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release \
    -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
cmake --build "$build" --target datachannel -j "${RCTL_TEST_JOBS:-4}"
opus=$(brew --prefix opus)
clang++ -std=c++17 -Icore -I"$dc/include" -I"$dc/deps/json/single_include" \
    -I"$opus/include" tests/WebRTCSessionOwnershipTest.cpp core/net/WebRTCPermissions.cpp \
    -L"$build" -ldatachannel -L"$opus/lib" -lopus -framework AudioToolbox \
    -Wl,-rpath,"$build" -o "$build/ownership-test"
"$build/ownership-test"
clang++ -std=c++17 -Icore -I"$dc/include" -I"$dc/deps/json/single_include" \
    -I"$opus/include" tests/TalkSpeakerQueueTest.cpp core/net/WebRTCPermissions.cpp \
    -L"$build" -ldatachannel -L"$opus/lib" -lopus -framework AudioToolbox \
    -Wl,-rpath,"$build" -o "$build/talk-speaker-test"
"$build/talk-speaker-test"
