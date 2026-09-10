#!/usr/bin/env bash
# Isolated host spike using the same Mbed TLS source revision as the device.
# It generates throwaway keys, binds loopback only, and never changes trust stores.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PORT="${RCTL_TLS_PROBE_PORT:-18443}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rctl-tls-probe.XXXXXX")"
BUILD="${RCTL_TLS_PROBE_BUILD:-$TMP/build}"
PID=""
cleanup() {
  if [[ -n "$PID" ]]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077
cmake -S "$ROOT/third_party/webrtc/.lib/ios/mbedtls" -B "$BUILD" -DENABLE_PROGRAMS=ON -DENABLE_TESTING=OFF
cmake --build "$BUILD" --target ssl_server2 -j 4
for name in server other; do
  openssl req -x509 -sha256 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve -nodes -days 1 \
    -subj /CN=rctl-test -addext subjectAltName=IP:127.0.0.1 \
    -addext extendedKeyUsage=serverAuth -addext keyUsage=digitalSignature -addext basicConstraints=critical,CA:FALSE \
    -keyout "$TMP/$name.key.pem" -out "$TMP/$name.cert.pem" >/dev/null 2>&1
  openssl x509 -in "$TMP/$name.cert.pem" -outform DER -out "$TMP/$name.cert.der"
done
swiftc -parse-as-library "$ROOT/scripts/experiments/LocalTLSProbe.swift" -o "$TMP/client"
"$BUILD/programs/ssl/ssl_server2" server_addr=127.0.0.1 server_port="$PORT" \
  crt_file="$TMP/server.cert.pem" key_file="$TMP/server.key.pem" auth_mode=none \
  min_version=tls13 max_version=tls13 >"$TMP/server.log" 2>&1 &
PID=$!
sleep 1
if ! kill -0 "$PID" 2>/dev/null; then cat "$TMP/server.log"; exit 1; fi
if ! "$TMP/client" "$PORT" "$TMP/server.cert.der" "$TMP/other.cert.der"; then cat "$TMP/server.log"; exit 1; fi
grep -q 'TLSv1.3' "$TMP/server.log"
echo 'Mbed TLS server negotiated TLS 1.3; no client certificate, no system trust changes.'
