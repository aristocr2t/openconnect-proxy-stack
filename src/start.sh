#!/bin/bash
set -euo pipefail

SOCKS_PORT="${SOCKS_PORT:-1080}"
CONNECT_PORT="${CONNECT_PORT:-3128}"
HTTP_CONNECT_PORT="${HTTP_CONNECT_PORT:-3129}"
MTPROTO_PORT="${MTPROTO_PORT:-8443}"

sysctl -w net.ipv4.conf.all.src_valid_mark=1 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true

# Fix DNS for openconnect
sed -i '/^options ndots:/d' /etc/resolv.conf 2>/dev/null || true

# ── TLS cert for HTTPS CONNECT ──
if [ ! -f /etc/tls/proxy.pem ]; then
  echo "[tls] Generating self-signed cert..."
  mkdir -p /etc/tls
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/tls/proxy.key -out /etc/tls/proxy.crt -subj "/CN=proxystack" 2>/dev/null
  cat /etc/tls/proxy.crt /etc/tls/proxy.key > /etc/tls/proxy.pem
  chmod 600 /etc/tls/proxy.pem
fi

# ── MTProto config (once) ──
if [ ! -f /etc/mtg/mtg.toml ]; then
  echo "[mtg] Generating MTProto config..."
  SECRET="${MTPROTO_SECRET:-$(mtg generate-secret --hex "${MTPROTO_FAKE_TLS:-cloudflare.com}")}"
  cat > /etc/mtg/mtg.toml <<EOF
secret = "${SECRET}"
bind-to = "0.0.0.0:${MTPROTO_PORT}"

[defense.blocklist]
enabled = false
EOF
fi

PROXY_PID=""
CONNECT_PID=""
HTTP_PID=""
MTG_PID=""
OC_PID=""

stop_services() {
  echo "[supervisor] stopping local proxies"
  for p in "$PROXY_PID" "$CONNECT_PID" "$HTTP_PID" "$MTG_PID"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
  done
  PROXY_PID=""; CONNECT_PID=""; HTTP_PID=""; MTG_PID=""
}

start_services() {
  iptables -t nat -D POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || true
  iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || true

  echo "[socks5] SOCKS5 on 0.0.0.0:${SOCKS_PORT}..."
  export SOCKS5_USER SOCKS5_PASS
  python3 /proxy.py "$SOCKS_PORT" 0.0.0.0 &
  PROXY_PID=$!

  echo "[connect] HTTPS CONNECT on 0.0.0.0:${CONNECT_PORT}..."
  CONNECT_TLS=1 python3 /connect.py "$CONNECT_PORT" 0.0.0.0 &
  CONNECT_PID=$!

  # Plain HTTP CONNECT: the same connect.py, its own credentials (HTTP_USER/HTTP_PASS).
  echo "[connect] HTTP CONNECT on 0.0.0.0:${HTTP_CONNECT_PORT}..."
  CONNECT_TLS=0 python3 /connect.py "$HTTP_CONNECT_PORT" 0.0.0.0 "${HTTP_USER:-}" "${HTTP_PASS:-}" &
  HTTP_PID=$!

  echo "[mtg] MTProto on 0.0.0.0:${MTPROTO_PORT}..."
  mtg run /etc/mtg/mtg.toml &
  MTG_PID=$!

  sleep 1
  echo "[ready] SOCKS5:${PROXY_PID} CONNECT:${CONNECT_PID} HTTP:${HTTP_PID} MTG:${MTG_PID}"
}

monitor_services() {
  while kill -0 "$OC_PID" 2>/dev/null; do
    if ! kill -0 "$PROXY_PID" 2>/dev/null; then
      echo "[supervisor] SOCKS5 died, restarting..." >&2
      python3 /proxy.py "$SOCKS_PORT" 0.0.0.0 &
      PROXY_PID=$!
    fi
    if ! kill -0 "$CONNECT_PID" 2>/dev/null; then
      echo "[supervisor] CONNECT died, restarting..." >&2
      CONNECT_TLS=1 python3 /connect.py "$CONNECT_PORT" 0.0.0.0 &
      CONNECT_PID=$!
    fi
    if ! kill -0 "$HTTP_PID" 2>/dev/null; then
      echo "[supervisor] HTTP CONNECT died, restarting..." >&2
      CONNECT_TLS=0 python3 /connect.py "$HTTP_CONNECT_PORT" 0.0.0.0 "${HTTP_USER:-}" "${HTTP_PASS:-}" &
      HTTP_PID=$!
    fi
    if ! kill -0 "$MTG_PID" 2>/dev/null; then
      echo "[supervisor] MTG died, restarting..." >&2
      mtg run /etc/mtg/mtg.toml &
      MTG_PID=$!
    fi
    sleep 30
  done
}

# Pin from /etc/mtg/vpn-pin, or computed once and saved there. This VPN is reached by IP,
# so its certificate never matches the address and openconnect needs an explicit pin.
resolve_pin() { # resolve_pin <ip>
  if [ -s /etc/mtg/vpn-pin ]; then cat /etc/mtg/vpn-pin; return 0; fi
  PIN_B64=$(echo | timeout 20 openssl s_client -connect "${1}:443" 2>/dev/null \
    | openssl x509 -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform der 2>/dev/null \
    | openssl dgst -sha256 -binary 2>/dev/null \
    | openssl base64 2>/dev/null | tr -d '\n')
  if [ -z "$PIN_B64" ]; then
    echo "[vpn] WARN: could not compute the certificate pin for $1, connecting without it" >&2
    return 0
  fi
  echo "pin-sha256:${PIN_B64}" > /etc/mtg/vpn-pin
  echo "[vpn] Certificate pin obtained and saved to /etc/mtg/vpn-pin: pin-sha256:${PIN_B64}" >&2
  echo "pin-sha256:${PIN_B64}"
}

# ── supervisor: VPN + services, forever ──
while true; do
  echo "[vpn] Resolving $OC_SERVER ..."
  if echo "$OC_SERVER" | grep -Eq "^[0-9]{1,3}(\.[0-9]{1,3}){3}$"; then
    VPN_IP="$OC_SERVER"
  else
    VPN_IP=$(nslookup "$OC_SERVER" 2>/dev/null | awk '/^Address: / {print $2}' | tail -1)
  fi
  if [ -z "$VPN_IP" ]; then
    echo "[vpn] ERROR: cannot resolve $OC_SERVER, retrying in 15s" >&2
    sleep 15
    continue
  fi
  echo "[vpn] $OC_SERVER → $VPN_IP"

  # DPD + reconnect so a dead peer is noticed instead of hanging silently.
  OC_ARGS="--interface=tun0 --force-dpd=30 --reconnect-timeout=300"
  PIN=$(resolve_pin "$VPN_IP")
  [ -n "$PIN" ] && OC_ARGS="$OC_ARGS --servercert $PIN"

  echo "[vpn] Connecting to $VPN_IP ..."
  CRED_FILE=$(mktemp)
  chmod 600 "$CRED_FILE"
  printf '%s\n' "$OC_USER" "$OC_PASS" > "$CRED_FILE"
  openconnect $OC_ARGS < "$CRED_FILE" "$VPN_IP" &
  OC_PID=$!

  UP=0
  for i in $(seq 1 60); do
    if ip link show tun0 &>/dev/null; then
      IPV4=$(ip -4 addr show tun0 2>/dev/null | awk '/inet / {print $2}')
      if [ -n "$IPV4" ]; then
        echo "[vpn] tun0 UP after ${i}s (${IPV4})"
        UP=1
        break
      fi
    fi
    kill -0 "$OC_PID" 2>/dev/null || break
    sleep 1
  done
  rm -f "$CRED_FILE"

  if [ "$UP" != "1" ]; then
    echo "[vpn] ERROR: tunnel not established, retrying in 10s" >&2
    kill "$OC_PID" 2>/dev/null || true
    wait "$OC_PID" 2>/dev/null || true
    sleep 10
    continue
  fi

  start_services
  monitor_services

  echo "[vpn] openconnect exited — restarting VPN and services in 5s" >&2
  stop_services
  sleep 5
done
