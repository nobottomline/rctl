#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 RELEASE_DIR VERSION SOURCE_SHA" >&2
  exit 2
}

[[ $# -eq 3 ]] || usage
release_dir=$1
version=$2
source_sha=$3

[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo "invalid release version: $version" >&2
  exit 1
}
[[ $source_sha =~ ^[0-9a-f]{40}$ ]] || {
  echo "invalid source commit: $source_sha" >&2
  exit 1
}
[[ -d $release_dir && ! -L $release_dir ]] || {
  echo "release directory is missing or is a symlink: $release_dir" >&2
  exit 1
}

package="rctl_${version}_iphoneos-arm.deb"
expected=(
  install.sh
  rctl-relay_linux_amd64
  rctl-relay_linux_arm64
  rctl-setup_linux_amd64
  rctl-setup_linux_arm64
  "$package"
)
catalog=rctl-update-stable.json
if [[ -e "$release_dir/$catalog" || ${RCTL_REQUIRE_UPDATE_CATALOG:-0} == 1 ]]; then
  expected+=("$catalog")
fi

mapfile -t expected < <(printf '%s\n' "${expected[@]}" | LC_ALL=C sort)

actual=()
while IFS= read -r name; do
  actual+=("$name")
done < <(find "$release_dir" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)

if [[ ${#actual[@]} -ne ${#expected[@]} ]]; then
  printf 'release set contains unexpected files:\n' >&2
  printf '  %s\n' "${actual[@]}" >&2
  exit 1
fi
for index in "${!expected[@]}"; do
  if [[ ${actual[$index]} != "${expected[$index]}" ]]; then
    printf 'release set mismatch at item %d: expected %s, found %s\n' \
      "$index" "${expected[$index]}" "${actual[$index]}" >&2
    exit 1
  fi
done
for name in "${expected[@]}"; do
  [[ -f "$release_dir/$name" && ! -L "$release_dir/$name" ]] || {
    echo "release artifact is not a regular file: $name" >&2
    exit 1
  }
done
for name in install.sh rctl-relay_linux_amd64 rctl-relay_linux_arm64 rctl-setup_linux_amd64 rctl-setup_linux_arm64; do
  [[ -x "$release_dir/$name" ]] || {
    echo "release executable is not executable: $name" >&2
    exit 1
  }
done

[[ $(dpkg-deb -f "$release_dir/$package" Package) == com.greatlove.rctl ]] || {
  echo "device package id does not match com.greatlove.rctl" >&2
  exit 1
}
[[ $(dpkg-deb -f "$release_dir/$package" Version) == "$version" ]] || {
  echo "device package version does not match $version" >&2
  exit 1
}
[[ $(dpkg-deb -f "$release_dir/$package" Architecture) == iphoneos-arm ]] || {
  echo "device package architecture does not match iphoneos-arm" >&2
  exit 1
}

assert_elf_arch() {
  local name=$1 pattern=$2 description
  description=$(file -b "$release_dir/$name")
  [[ $description =~ $pattern ]] || {
    echo "$name has unexpected binary format: $description" >&2
    exit 1
  }
}
assert_elf_arch rctl-setup_linux_amd64 'ELF 64-bit LSB.*(x86-64|x86_64)'
assert_elf_arch rctl-relay_linux_amd64 'ELF 64-bit LSB.*(x86-64|x86_64)'
assert_elf_arch rctl-setup_linux_arm64 'ELF 64-bit LSB.*(ARM aarch64|aarch64)'
assert_elf_arch rctl-relay_linux_arm64 'ELF 64-bit LSB.*(ARM aarch64|aarch64)'

if [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]]; then
  expected_version="rctl-setup $version ($source_sha) linux/amd64"
  actual_version=$("$release_dir/rctl-setup_linux_amd64" version)
  [[ $actual_version == "$expected_version" ]] || {
    printf 'setup build metadata mismatch:\n  expected: %s\n  actual:   %s\n' "$expected_version" "$actual_version" >&2
    exit 1
  }
elif [[ ${RCTL_REQUIRE_EXECUTABLE_CHECK:-0} == 1 ]]; then
  echo "cannot execute the linux/amd64 setup binary on this verification host" >&2
  exit 1
else
  echo "warning: setup build metadata execution check skipped on $(uname -s)/$(uname -m)" >&2
fi

(
  cd "$release_dir"
  rm -f SHA256SUMS
  LC_ALL=C sha256sum -- "${expected[@]}" > SHA256SUMS
  sha256sum --check --strict SHA256SUMS
)
