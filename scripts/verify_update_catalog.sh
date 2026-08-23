#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 MANIFEST TARGET_PACKAGE" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
manifest=$1
target_package=$2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin="${RCTL_UPDATE_PUBLIC_KEY:-$root/layout/usr/local/share/rctl/update-public-key.pem}"
artifacts_dir="${RCTL_UPDATE_CATALOG_ARTIFACTS_DIR:-}"
work="$(mktemp -d "${TMPDIR:-/tmp}/rctl-update-catalog.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'update catalog verification failed: %s\n' "$*" >&2
  exit 1
}

decode_base64() {
  base64 --decode 2>/dev/null || base64 -D
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

for file in "$manifest" "$target_package" "$pin"; do
  [[ -f $file && ! -L $file ]] || fail "required input is not a regular file: $file"
done
[[ $(wc -c < "$manifest" | tr -d '[:space:]') -le 262144 ]] || fail "manifest is too large"

jq -e 'type == "object" and (keys == ["payload", "signature"]) and
  (.payload | type == "string") and (.signature | type == "string")' "$manifest" >/dev/null || \
  fail "envelope schema is invalid"
jq -er .payload "$manifest" | decode_base64 > "$work/payload.json" || fail "payload is not valid base64"
jq -er .signature "$manifest" | decode_base64 > "$work/signature.der" || fail "signature is not valid base64"
openssl dgst -sha256 -verify "$pin" -signature "$work/signature.der" "$work/payload.json" >/dev/null 2>&1 || \
  fail "ECDSA signature does not match the pinned update key"

jq -e '
  . as $catalog |
  type == "object" and
  (keys == ["artifacts", "channel", "protocol_major", "schema", "target_version"]) and
  .schema == 1 and .protocol_major == 1 and .channel == "stable" and
  (.target_version | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")) and
  (.artifacts | type == "array" and length >= 2 and
    (map(.version) | unique | length) == length and
    all(type == "object" and (keys == ["sha256", "size", "url", "version"]) and
      (.version | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")) and
      (.url | type == "string") and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.size | type == "number" and floor == . and . > 0 and . <= 536870912))) and
  ([.artifacts[].version] | index($catalog.target_version)) != null
' "$work/payload.json" >/dev/null || fail "signed payload schema is invalid"

target_version="$(dpkg-deb -f "$target_package" Version)"
[[ $(dpkg-deb -f "$target_package" Package) == com.greatlove.rctl ]] || fail "target package ID is invalid"
[[ $(dpkg-deb -f "$target_package" Architecture) == iphoneos-arm ]] || fail "target package architecture is invalid"
[[ $(jq -r .target_version "$work/payload.json") == "$target_version" ]] || fail "target package version does not match catalog target"

while IFS= read -r encoded; do
  item="$(printf '%s' "$encoded" | decode_base64)"
  version="$(jq -r .version <<<"$item")"
  url="$(jq -r .url <<<"$item")"
  expected_sha="$(jq -r .sha256 <<<"$item")"
  expected_size="$(jq -r .size <<<"$item")"
  expected_name="rctl_${version}_iphoneos-arm.deb"

  [[ $url == https://* && $url != *[$'\r\n\t ']* && $url != *'?'* && $url != *'#'* && $url != *'%'* ]] || \
    fail "artifact $version does not use a plain HTTPS URL"
  authority="${url#https://}"
  authority="${authority%%/*}"
  [[ -n $authority && $authority != *'@'* && $url != "https://$authority" ]] || fail "artifact $version URL authority is invalid"
  [[ ${url##*/} == "$expected_name" ]] || fail "artifact $version URL filename is invalid"

  package="$work/$expected_name"
  if [[ $version == "$target_version" ]]; then
    cp "$target_package" "$package"
  elif [[ -n $artifacts_dir ]]; then
    [[ -d $artifacts_dir && ! -L $artifacts_dir && -f "$artifacts_dir/$expected_name" && ! -L "$artifacts_dir/$expected_name" ]] || \
      fail "offline artifact $version is missing or unsafe"
    cp "$artifacts_dir/$expected_name" "$package"
  else
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
      --retry 3 --connect-timeout 15 --max-time 300 "$url" --output "$package"
  fi
  [[ $(wc -c < "$package" | tr -d '[:space:]') == "$expected_size" ]] || fail "artifact $version size mismatch"
  [[ $(sha256_file "$package") == "$expected_sha" ]] || fail "artifact $version SHA-256 mismatch"
  [[ $(dpkg-deb -f "$package" Package) == com.greatlove.rctl ]] || fail "artifact $version package ID is invalid"
  [[ $(dpkg-deb -f "$package" Version) == "$version" ]] || fail "artifact $version Debian version mismatch"
  [[ $(dpkg-deb -f "$package" Architecture) == iphoneos-arm ]] || fail "artifact $version architecture is invalid"
done < <(jq -rc '.artifacts[] | @base64' "$work/payload.json")

printf 'signed update catalog verified: target %s, %s rollback-capable artifacts\n' \
  "$target_version" "$(jq '.artifacts | length' "$work/payload.json")"
