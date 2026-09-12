#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JUICE="${1:-$ROOT/.lib/libdatachannel/deps/libjuice}"
EXPECTED=3c40a3545b6b1b62c7adee7f8f2bd58aa290afd6
PATCH="$ROOT/patches/libjuice-ice-role-presence.patch"

if [[ "$(git -C "$JUICE" rev-parse HEAD)" != "$EXPECTED" ]]; then
  echo 'Unexpected libjuice revision; review the ICE compatibility patch before building.' >&2
  exit 1
fi
if git -C "$JUICE" apply --reverse --check "$PATCH" 2>/dev/null; then
  echo 'libjuice ICE role patch already applied'
elif git -C "$JUICE" apply --check "$PATCH"; then
  git -C "$JUICE" apply "$PATCH"
  echo 'Applied libjuice ICE role patch'
else
  echo 'libjuice patch does not match the source; refusing a partial or drifting build.' >&2
  exit 1
fi
