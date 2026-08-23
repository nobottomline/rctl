#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="${RCTL_UPDATE_SIGNING_KEY:-${HOME}/.config/rctl/update-signing-key.pem}"
PIN="${RCTL_UPDATE_PUBLIC_KEY:-${ROOT}/layout/usr/local/share/rctl/update-public-key.pem}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rctl-update-key.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

fail() {
  printf 'update signing key check failed: %s\n' "$*" >&2
  exit 1
}

[[ -f "${KEY}" && ! -L "${KEY}" ]] || fail "private key must be a regular, non-symlink file: ${KEY}"
[[ -f "${PIN}" && ! -L "${PIN}" ]] || fail "public key pin is missing: ${PIN}"

mode="$(stat -c '%a' -- "${KEY}" 2>/dev/null || true)"
if [[ ! "${mode}" =~ ^[0-7]{3,4}$ ]]; then
  mode="$(stat -f '%Lp' "${KEY}" 2>/dev/null || true)"
fi
[[ "${mode}" =~ ^[0-7]{3,4}$ ]] || fail "could not determine private key mode"
[[ "${mode}" == "600" ]] || fail "private key mode must be 600, got ${mode}"

openssl ec -in "${KEY}" -text -noout 2>/dev/null | grep -Eq 'ASN1 OID: prime256v1|NIST CURVE: P-256' || \
  fail "private key must use P-256"
openssl ec -in "${KEY}" -pubout -out "${WORK}/derived.pem" 2>/dev/null || fail "private key is not a valid EC key"
openssl pkey -pubin -in "${WORK}/derived.pem" -pubout -outform DER > "${WORK}/derived.der" 2>/dev/null
openssl pkey -pubin -in "${PIN}" -pubout -outform DER > "${WORK}/pinned.der" 2>/dev/null
cmp -s "${WORK}/derived.der" "${WORK}/pinned.der" || fail "private key does not match the package public key pin"

fingerprint="$(openssl dgst -sha256 "${WORK}/pinned.der" | awk '{print $NF}')"
printf 'update signing key verified: P-256 public SHA-256 %s\n' "${fingerprint}"
