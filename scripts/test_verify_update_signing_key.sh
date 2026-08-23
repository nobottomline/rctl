#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rctl-update-key-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

KEY="${WORK}/private.pem"
PIN="${WORK}/public.pem"

openssl ecparam -name prime256v1 -genkey -noout -out "${KEY}"
openssl ec -in "${KEY}" -pubout -out "${PIN}" 2>/dev/null
chmod 0600 "${KEY}"

RCTL_UPDATE_SIGNING_KEY="${KEY}" RCTL_UPDATE_PUBLIC_KEY="${PIN}" \
  "${ROOT}/scripts/verify-update-signing-key.sh" >/dev/null

chmod 0644 "${KEY}"
if RCTL_UPDATE_SIGNING_KEY="${KEY}" RCTL_UPDATE_PUBLIC_KEY="${PIN}" \
  "${ROOT}/scripts/verify-update-signing-key.sh" >/dev/null 2>&1; then
  echo "expected permissive private-key mode to be rejected" >&2
  exit 1
fi

echo "update signing key verifier tests passed"
