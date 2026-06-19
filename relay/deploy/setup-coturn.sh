#!/usr/bin/env bash
# Install + configure coturn (STUN/TURN) on the relay VPS, the standard
# self-hosted choice (Jitsi/Matrix/Nextcloud Talk use it). The relay mints
# short-lived TURN credentials from the shared secret and hands the ICE server
# list to the browser and device via signaling; coturn validates them with
# use-auth-secret (the "TURN REST API" scheme).
#
# Run as root on the VPS. Reuses an existing secret on re-run (idempotent), then
# prints the env lines to paste/keep in /etc/rctl-relay/relay.env. Open the same
# ports in the provider firewall too (ufw is often inactive on managed VPSes).
#
#   REALM=relay.example.com EXTIP=203.0.113.10 ./setup-coturn.sh
#
# TLS (turns://) reuses the relay's Let's Encrypt cert if present so browsers
# trust it on networks that block UDP. UDP 3478 is the standard STUN/TURN port;
# if it's already taken, set PORT to a free one (the relay URLs use whatever you
# pick — clients only know what the relay tells them).
set -euo pipefail

REALM="${REALM:?set REALM to the relay's public hostname}"
EXTIP="${EXTIP:?set EXTIP to the VPS public IPv4}"
PORT="${PORT:-3478}"
TLS_PORT="${TLS_PORT:-5349}"
MINP="${MINP:-49160}"
MAXP="${MAXP:-49200}"
CERT="/etc/letsencrypt/live/$REALM/fullchain.pem"
PKEY="/etc/letsencrypt/live/$REALM/privkey.pem"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq coturn acl

if grep -q '^static-auth-secret=' /etc/turnserver.conf 2>/dev/null; then
  SECRET=$(grep '^static-auth-secret=' /etc/turnserver.conf | head -1 | cut -d= -f2)
else
  SECRET=$(openssl rand -hex 32)
fi

# Let coturn read the Let's Encrypt cert (survives renewals via the dir ACL).
TLS_OK=0
if [ -f "$CERT" ]; then
  setfacl -m u:turnserver:rX /etc/letsencrypt/live /etc/letsencrypt/archive 2>/dev/null || true
  setfacl -R -m u:turnserver:rX "/etc/letsencrypt/live/$REALM" /etc/letsencrypt/archive 2>/dev/null || true
  sudo -u turnserver test -r "$CERT" && TLS_OK=1 || TLS_OK=0
fi

cat > /etc/turnserver.conf <<EOF
# rctl TURN/STUN (coturn) — time-limited HMAC creds minted by the relay.
listening-port=$PORT
tls-listening-port=$TLS_PORT
listening-ip=0.0.0.0
listening-ip=::
external-ip=$EXTIP
realm=$REALM
server-name=$REALM
fingerprint
use-auth-secret
static-auth-secret=$SECRET
min-port=$MINP
max-port=$MAXP
$( [ "$TLS_OK" = 1 ] && echo "cert=$CERT" || echo "# TLS cert not found at $CERT" )
$( [ "$TLS_OK" = 1 ] && echo "pkey=$PKEY" || echo "# TLS pkey not found" )
no-cli
no-multicast-peers
no-tlsv1
no-tlsv1_1
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=::1
total-quota=100
stale-nonce=600
EOF
chmod 640 /etc/turnserver.conf
chown root:turnserver /etc/turnserver.conf 2>/dev/null || true

sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn 2>/dev/null \
  || echo "TURNSERVER_ENABLED=1" > /etc/default/coturn
systemctl enable coturn >/dev/null 2>&1 || true
systemctl restart coturn
sleep 2

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT" >/dev/null 2>&1 || true
  ufw allow "$TLS_PORT" >/dev/null 2>&1 || true
  ufw allow "$MINP:$MAXP/udp" >/dev/null 2>&1 || true
fi

echo "coturn: $(systemctl is-active coturn) on $PORT/$TLS_PORT (TLS=$TLS_OK)"
echo
echo "Add to /etc/rctl-relay/relay.env (the secret must match coturn's):"
echo "RCTL_RELAY_TURN_SECRET=$SECRET"
echo "RCTL_RELAY_TURN_URLS=turn:$REALM:$PORT?transport=udp,turn:$REALM:$PORT?transport=tcp$( [ "$TLS_OK" = 1 ] && echo ",turns:$REALM:$TLS_PORT?transport=tcp" )"
echo "RCTL_RELAY_STUN_URLS=stun:$REALM:$PORT"
echo
echo "Also open $PORT (udp+tcp), $TLS_PORT (tcp), $MINP-$MAXP (udp) in the provider firewall."
