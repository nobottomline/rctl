#!/usr/bin/env bash
# Guided: turn the public LAN-only .deb into a personalized relay .deb for YOUR
# device — no build tools required. It talks to your already-running relay to
# mint a one-time enrollment token, then injects it into a copy of the public
# package (see scripts/personalize_deb.sh; only dpkg-deb is needed, not Theos).
#
# Usage (interactive):   scripts/make-device-deb.sh
# Usage (scripted):      RELAY_URL_BASE=https://rctl.example.com:9443 \
#                        RCTL_ADMIN_SECRET=... DEVICE_NAME="iPad Air 3" \
#                        scripts/make-device-deb.sh [base.deb]
#
# Optional: RCTL_CURL_INSECURE=1 to accept a self-signed TLS cert (IP-only setups).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

RELAY_URL_BASE="${RELAY_URL_BASE:-}"
ADMIN_SECRET="${RCTL_ADMIN_SECRET:-}"
DEVICE_NAME="${DEVICE_NAME:-}"
BASE_DEB="${1:-}"

CURL=(curl -fsS)
[[ "${RCTL_CURL_INSECURE:-0}" == "1" ]] && CURL+=(-k)

if [[ -z "$RELAY_URL_BASE" ]]; then
  read -rp "Relay public URL (e.g. https://rctl.example.com:9443): " RELAY_URL_BASE
fi
if [[ -z "$ADMIN_SECRET" ]]; then
  read -rsp "Relay admin secret: " ADMIN_SECRET; echo
fi
if [[ -z "$DEVICE_NAME" ]]; then
  read -rp "Device name [iPad]: " DEVICE_NAME; DEVICE_NAME="${DEVICE_NAME:-iPad}"
fi

BASE="${RELAY_URL_BASE%/}"
case "$BASE" in
  https://*|http://*) ;;
  *) echo "error: relay URL must start with http:// or https://" >&2; exit 2;;
esac

extract_json_string() { sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p"; }

COOKIES="$(mktemp "${TMPDIR:-/tmp}/rctl-cookies.XXXXXX")"
trap 'rm -f "$COOKIES"' EXIT

echo "==> Logging in to $BASE/admin"
# Send the secret as a JSON string. Admin secrets generated with the documented
# `openssl rand -base64 48` contain no quotes/backslashes, so direct embedding is
# safe and keeps this script dependency-free (just curl + dpkg-deb).
LOGIN_BODY="$(printf '{"secret":"%s"}' "$ADMIN_SECRET")"
if ! "${CURL[@]}" -c "$COOKIES" -H 'Content-Type: application/json' \
      -d "$LOGIN_BODY" "$BASE/api/admin/login" >/dev/null; then
  echo "error: login failed — check the admin secret and that the relay is reachable" >&2
  exit 1
fi

echo "==> Creating a one-time enrollment token"
ENROLL_JSON="$("${CURL[@]}" -b "$COOKIES" -X POST "$BASE/api/admin/enrollments")"
TOKEN="$(printf '%s' "$ENROLL_JSON" | extract_json_string token)"
RELAY_WSS="$(printf '%s' "$ENROLL_JSON" | extract_json_string relay_url)"
if [[ -z "$TOKEN" || -z "$RELAY_WSS" ]]; then
  echo "error: could not parse enrollment response: $ENROLL_JSON" >&2
  exit 1
fi

if [[ -z "$BASE_DEB" ]]; then
  BASE_DEB="$(ls -t "$ROOT"/packages/*.deb 2>/dev/null | head -1 || true)"
fi
if [[ -z "$BASE_DEB" || ! -f "$BASE_DEB" ]]; then
  echo "error: no base .deb found — download the public release into packages/ or run 'make package'" >&2
  exit 1
fi

echo "==> Personalizing $(basename "$BASE_DEB") (no compilation)"
OUT="$(RELAY_URL="$RELAY_WSS" ENROLL_TOKEN="$TOKEN" DEVICE_NAME="$DEVICE_NAME" \
       "$ROOT/scripts/personalize_deb.sh" "$BASE_DEB")"

cat <<DONE

Done. Your personalized package:
  $OUT

Next:
  1. Install it on the jailbroken device (AppSync/TrollStore/dpkg -i).
  2. Open $BASE/admin and approve the device when it shows up as pending.
  3. Open $BASE/control/devices/<id> to control it over the internet.

Keep this .deb private — it embeds your one-time enrollment token.
DONE
