#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JUICE="$ROOT/.lib/libdatachannel/deps/libjuice"
bash "$ROOT/apply-patches.sh" "$JUICE"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rctl-ice-role.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
cmake -S "$JUICE" -B "$BUILD" -G Ninja -DNO_TESTS=ON \
  -DBUILD_SHARED_LIBS=OFF -DENABLE_LOCALHOST_ADDRESS=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build "$BUILD" --target juice-static -j 4
"${CC:-cc}" -std=c11 -DJUICE_STATIC -I "$JUICE/src" -I "$JUICE/include" \
  -I "$JUICE/include/juice" "$ROOT/tests/ice-role.c" "$BUILD/libjuice-static.a" \
  -pthread -o "$BUILD/ice-role-test"
"$BUILD/ice-role-test"
