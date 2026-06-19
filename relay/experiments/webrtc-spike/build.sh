#!/usr/bin/env bash
# Build the native (libdatachannel) spike peer against the locally-built library.
set -euo pipefail
cd "$(dirname "$0")"
L=.lib/libdatachannel
[ -f "$L/build/libdatachannel.dylib" ] || { echo "build libdatachannel first (see README)"; exit 1; }
RPATH="$(cd "$L/build" && pwd)"
for src in native_peer relay_device; do
  clang++ -std=c++17 -O2 "$src.cpp" \
    -I"$L/include" -I"$L/deps/json/single_include" \
    -L"$L/build" -ldatachannel \
    -Wl,-rpath,"$RPATH" \
    -o "$src"
  echo "built ./$src"
done
