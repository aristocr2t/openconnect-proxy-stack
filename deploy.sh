#!/usr/bin/env bash
# Control the proxy server: deploy/redeploy and removal.
#   ./deploy.sh          deploy or redeploy (build → start → verify)
#   ./deploy.sh creds    enter/change credentials (.env) and redeploy
#   ./deploy.sh status   containers, ports, recent logs
#   ./deploy.sh logs     VPN container logs (tail -f)
#   ./deploy.sh remove   remove containers, image and volume
set -euo pipefail

cd "$(dirname "$0")"
for p in /usr/local/bin /opt/homebrew/bin /Applications/Docker.app/Contents/Resources/bin; do
  [ -d "$p" ] && PATH="$p:$PATH"
done
ENV_FILE=".env"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
log()   { green "[+] $*"; }

load_env() {
  if [ -f "$ENV_FILE" ]; then
    set -a; . "./$ENV_FILE"; set +a
  fi
  HTTP_PORT="${HTTP_PORT:-2080}"
  HTTPS_PORT="${HTTPS_PORT:-2443}"
  SOCKS_PORT="${SOCKS_PORT:-2085}"
  MTPROTO_PORT="${MTPROTO_PORT:-2444}"
}

get_var() { eval "printf '%s' \"\${$1:-}\""; }

dotenv_safe() { # dotenv_safe <value> — .env values are written in single quotes, so no quote inside
  case "$1" in
    *"'"*) red "  a single quote is not supported: it breaks .env"; return 1 ;;
  esac
}

ask() { # ask VAR "question" — Enter keeps the current value
  local cur answer
  cur=$(get_var "$1")
  while :; do
    read -r -p "$2${cur:+ [$cur]}: " answer
    if [ -n "$answer" ]; then
      if dotenv_safe "$answer"; then printf -v "$1" '%s' "$answer"; return 0; fi
      continue
    fi
    [ -n "$cur" ] && return 0
    red "  a value is required"
  done
}

ask_secret() { # ask_secret VAR "question" — input is hidden, Enter keeps the current value
  local cur answer
  cur=$(get_var "$1")
  while :; do
    read -r -s -p "$2${cur:+ [keep current]}: " answer; echo
    if [ -n "$answer" ]; then
      if dotenv_safe "$answer"; then printf -v "$1" '%s' "$answer"; return 0; fi
      continue
    fi
    [ -n "$cur" ] && return 0
    red "  a value is required"
  done
}

ask_pair() { # ask_pair USER_VAR PASS_VAR "Protocol name"
  ask "$1" "$3: login"
  ask_secret "$2" "$3: password"
}

ask_creds() { # asks for every credential: Enter keeps the current value
  ask OC_SERVER "VPN server (IP or hostname)"
  ask OC_USER "VPN login"
  ask_secret OC_PASS "VPN password"
  ask_pair SOCKS5_USER SOCKS5_PASS "SOCKS5"
  ask_pair HTTP_USER HTTP_PASS "HTTP CONNECT"
  ask_pair HTTPS_USER HTTPS_PASS "HTTPS CONNECT"
}

write_env() {
  umask 077
  # Values are single-quoted: this script sources .env and compose parses it too,
  # and only quoting keeps $, spaces and # intact in both readers.
  cat > "$ENV_FILE" <<EOF
# OpenConnect VPN
OC_SERVER='$OC_SERVER'
OC_USER='$OC_USER'
OC_PASS='$OC_PASS'

# SOCKS5 — port and its own login/password pair
SOCKS_PORT=$SOCKS_PORT
SOCKS5_USER='$SOCKS5_USER'
SOCKS5_PASS='$SOCKS5_PASS'

# HTTP CONNECT (no TLS) — port and its own login/password pair
HTTP_PORT=$HTTP_PORT
HTTP_USER='$HTTP_USER'
HTTP_PASS='$HTTP_PASS'

# HTTPS CONNECT (TLS) — port and its own login/password pair
HTTPS_PORT=$HTTPS_PORT
HTTPS_USER='$HTTPS_USER'
HTTPS_PASS='$HTTPS_PASS'

# MTProto (Telegram) — port and its own secret instead of a login/password.
# Empty = generate on the first run.
MTPROTO_PORT=$MTPROTO_PORT
MTPROTO_SECRET='${MTPROTO_SECRET:-}'
MTPROTO_FAKE_TLS='${MTPROTO_FAKE_TLS:-cloudflare.com}'
EOF
  chmod 600 "$ENV_FILE"
  log "Credentials written to $ENV_FILE"
}

probe() { # probe "label" LOGIN PASSWORD <curl proxy options>
  local label="$1" user="$2" pass="$3" ip
  shift 3
  if [ -n "$user" ]; then
    ip=$(curl -sS -m 25 --proxy-user "${user}:${pass}" "$@" https://ifconfig.me 2>/dev/null || true)
  else
    ip=$(curl -sS -m 25 "$@" https://ifconfig.me 2>/dev/null || true)
  fi
  if [ -n "$ip" ]; then
    green "  $label OK — exit IP: $ip"
  else
    red "  $label FAIL"
    return 1
  fi
}

deploy() {
  if [ ! -f "$ENV_FILE" ] || [ -z "$(get_var SOCKS5_USER)" ] || [ -z "$(get_var HTTP_USER)" ] || [ -z "$(get_var HTTPS_USER)" ]; then
    [ -t 0 ] || { red "No complete credentials in $ENV_FILE — run ./deploy.sh interactively or create .env from .env.example"; exit 1; }
    log "Entering credentials (Enter = keep the current value)"
    ask_creds
    write_env
  fi

  log "Building and starting (waiting for health)"
  docker compose up -d --build --wait --wait-timeout 180 --remove-orphans || {
    red "The stack did not come up healthy"
    docker compose ps
    exit 1
  }

  echo
  docker compose ps
  echo
  log "Checking the proxies (every protocol has its own credentials):"
  local fail=0
  probe "SOCKS5  :${SOCKS_PORT}"  "${SOCKS5_USER:-}" "${SOCKS5_PASS:-}" --socks5-hostname "127.0.0.1:${SOCKS_PORT}" || fail=1
  probe "HTTPS   :${HTTPS_PORT}" "${HTTPS_USER:-}"  "${HTTPS_PASS:-}"  --proxy "https://127.0.0.1:${HTTPS_PORT}" --proxy-insecure || fail=1
  probe "HTTP    :${HTTP_PORT}"  "${HTTP_USER:-}"   "${HTTP_PASS:-}"   --proxy "http://127.0.0.1:${HTTP_PORT}" || fail=1
  echo
  log "MTProto :${MTPROTO_PORT} (port published by proxystack-mtproto, the secret is the login)"
  echo
  if [ "$fail" = 0 ]; then
    log "Done. Details: ./deploy.sh status"
  else
    red "Some checks failed. Logs: ./deploy.sh logs"
  fi
}

status() {
  docker compose ps || true
  echo
  echo "SOCKS5  : localhost:${SOCKS_PORT}  login: ${SOCKS5_USER:-<no auth>}"
  echo "HTTP    : localhost:${HTTP_PORT}   login: ${HTTP_USER:-<no auth>}"
  echo "HTTPS   : localhost:${HTTPS_PORT}  login: ${HTTPS_USER:-<no auth>}"
  echo "MTProto : localhost:${MTPROTO_PORT}  secret: docker exec proxystack-vpn cat /etc/mtg/mtg.toml"
  echo "VPN pin : $(docker exec proxystack-vpn cat /etc/mtg/vpn-pin 2>/dev/null || echo 'not obtained yet (appears on the first connection)')"
  echo
  echo "=== VPN logs (last 15) ==="
  docker logs proxystack-vpn 2>&1 | tail -15 || true
}

load_env

case "${1:-deploy}" in
  deploy)  deploy ;;
  creds)   ask_creds; write_env; deploy ;;
  status)  status ;;
  logs)    docker logs -f proxystack-vpn ;;
  remove)
    log "Removing containers, network and volume..."
    docker compose down -v --remove-orphans
    docker rmi proxystack-vpn:latest 2>/dev/null || true
    log "Removed. To install again: ./deploy.sh"
    ;;
  help|-h|--help)
    sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    red "Unknown command: $1"
    echo "Commands: deploy | creds | status | logs | remove"
    exit 1
    ;;
esac
