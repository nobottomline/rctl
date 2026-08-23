#!/usr/bin/env bash
# Build a per-user .deb that enables the authenticated internet relay path.
#
# The normal release package remains LAN-only. This script injects only the
# caller-provided relay URL and enrollment token into a copy of an existing .deb.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_OUT_DIR="$ROOT/personalized"

usage() {
  cat <<'USAGE'
Usage:
  cp relay.env.example relay.env
  $EDITOR relay.env
  scripts/personalize_deb.sh [base.deb]

Or:
  RELAY_URL=wss://rctl.example.com/device \
  ENROLL_TOKEN=<long-random-token> \
  scripts/personalize_deb.sh [base.deb]

Optional:
  DEVICE_NAME="iPad Air 3"
  OUT_DIR=personalized
  RCTL_RELAY_ENV=/path/to/relay.env
  RELAY_2_URL=wss://backup.example.com/device
  RELAY_2_ENROLL_TOKEN=<second-relay-token>

Notes:
  - RELAY_URL must start with wss://.
  - ENROLL_TOKEN must be a per-user secret from your relay admin panel.
  - The generated .deb embeds that token; do not commit or publish it.
USAGE
}

xml_escape() {
  printf '%s' "$1" \
    | sed \
      -e 's/&/\&amp;/g' \
      -e 's/</\&lt;/g' \
      -e 's/>/\&gt;/g' \
      -e 's/"/\&quot;/g' \
      -e "s/'/\&apos;/g"
}

strip_optional_quotes() {
  local value="$1"
  if [[ "$value" == \"*\" && "$value" == *\" && "${#value}" -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' && "${#value}" -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

load_env_file() {
  local file="$1"
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
    key="${line%%=*}"
    value="$(strip_optional_quotes "${line#*=}")"
    case "$key" in
      RELAY_URL)
        [[ -z "${RELAY_URL:-}" ]] && RELAY_URL="$value"
        ;;
      ENROLL_TOKEN)
        [[ -z "${ENROLL_TOKEN:-}" ]] && ENROLL_TOKEN="$value"
        ;;
      DEVICE_NAME)
        [[ -z "${DEVICE_NAME:-}" ]] && DEVICE_NAME="$value"
        ;;
      OUT_DIR)
        [[ -z "${OUT_DIR:-}" ]] && OUT_DIR="$value"
        ;;
      RELAY_[2-9]_URL|RELAY_1[0-6]_URL|RELAY_[2-9]_ENROLL_TOKEN|RELAY_1[0-6]_ENROLL_TOKEN)
        [[ -z "${!key:-}" ]] && printf -v "$key" '%s' "$value"
        ;;
    esac
  done < "$file"
  return 0
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ENV_FILE="${RCTL_RELAY_ENV:-$ROOT/relay.env}"
if [[ -f "$ENV_FILE" ]]; then
  load_env_file "$ENV_FILE"
fi

RELAY_URL="${RELAY_URL:-}"
ENROLL_TOKEN="${ENROLL_TOKEN:-}"
DEVICE_NAME="${DEVICE_NAME:-}"
OUT_DIR="${OUT_DIR:-$DEFAULT_OUT_DIR}"
BASE_DEB="${1:-}"

if [[ -z "$RELAY_URL" || -z "$ENROLL_TOKEN" ]]; then
  usage >&2
  exit 2
fi
if [[ "$RELAY_URL" != wss://* ]]; then
  echo "error: RELAY_URL must start with wss://" >&2
  exit 2
fi
if [[ "${#ENROLL_TOKEN}" -lt 32 ]]; then
  echo "error: ENROLL_TOKEN must be at least 32 characters" >&2
  exit 2
fi

relay_urls=("$RELAY_URL")
relay_tokens=("$ENROLL_TOKEN")
for ((idx = 2; idx <= 16; idx++)); do
  url_key="RELAY_${idx}_URL"
  token_key="RELAY_${idx}_ENROLL_TOKEN"
  url="${!url_key:-}"
  token="${!token_key:-}"
  if [[ -z "$url" && -z "$token" ]]; then
    continue
  fi
  if [[ "$url" != wss://* ]]; then
    echo "error: ${url_key} must start with wss://" >&2
    exit 2
  fi
  if [[ "${#token}" -lt 32 ]]; then
    echo "error: ${token_key} must be at least 32 characters" >&2
    exit 2
  fi
  for existing in "${relay_urls[@]}"; do
    if [[ "$existing" == "$url" ]]; then
      echo "error: duplicate relay URL: $url" >&2
      exit 2
    fi
  done
  relay_urls+=("$url")
  relay_tokens+=("$token")
done
if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "error: dpkg-deb is required; install Theos packaging dependencies first" >&2
  exit 1
fi

if [[ -z "$BASE_DEB" ]]; then
  BASE_DEB="$(ls -t "$ROOT"/packages/*.deb 2>/dev/null | head -1 || true)"
fi
if [[ -z "$BASE_DEB" || ! -f "$BASE_DEB" ]]; then
  echo "error: base .deb not found; run 'make package' first or pass a .deb path" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rctl-personalize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

dpkg-deb -R "$BASE_DEB" "$WORK/pkg"
CFG_DIR="$WORK/pkg/var/mobile/Library/Preferences"
mkdir -p "$CFG_DIR"

{
cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Enabled</key>
	<true/>
	<key>DeviceName</key>
	<string>$(xml_escape "$DEVICE_NAME")</string>
	<key>LocalAccessEnabled</key>
	<true/>
	<key>Relays</key>
	<array>
PLIST
for i in "${!relay_urls[@]}"; do
cat <<PLIST
		<dict>
			<key>Enabled</key>
			<true/>
			<key>RelayURL</key>
			<string>$(xml_escape "${relay_urls[$i]}")</string>
			<key>EnrollToken</key>
			<string>$(xml_escape "${relay_tokens[$i]}")</string>
		</dict>
PLIST
done
cat <<'PLIST'
	</array>
</dict>
</plist>
PLIST
} > "$CFG_DIR/com.greatlove.rctl.relay.plist"
chmod 0644 "$CFG_DIR/com.greatlove.rctl.relay.plist"

BASE_NAME="$(basename "$BASE_DEB" .deb)"
OUT_DEB="$OUT_DIR/${BASE_NAME}+relay.deb"
dpkg-deb -b "$WORK/pkg" "$OUT_DEB" >/dev/null

echo "$OUT_DEB"
