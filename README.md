# openconnect-proxy-stack — OpenConnect VPN with four proxies in Docker

A single container runs an OpenConnect VPN (tun0) and four proxy protocols on top of it:
SOCKS5, HTTP CONNECT, HTTPS CONNECT (TLS) and MTProto for Telegram.
Host ports are published by small socat relays — Docker Desktop on macOS does not forward
ports to a container that owns a TUN interface, and a relay works around that.

## Ports

| Host port | Variable | Protocol | Auth |
|-----------|----------|----------|------|
| 2085 | `SOCKS_PORT` | SOCKS5 | `SOCKS5_USER` / `SOCKS5_PASS` |
| 2080 | `HTTP_PORT` | HTTP CONNECT | `HTTP_USER` / `HTTP_PASS` |
| 2443 | `HTTPS_PORT` | HTTPS CONNECT (TLS, self-signed) | `HTTPS_USER` / `HTTPS_PASS` |
| 2444 | `MTPROTO_PORT` | MTProto (Telegram) | secret `MTPROTO_SECRET` |

Host ports come from `.env`.

## Requirements

- Docker with Compose v2 (`docker compose`)
- `/dev/net/tun`, `NET_ADMIN`, `NET_RAW` for the container (already in the compose file)
- `curl` on the host — used by the post-deploy checks

## Install and redeploy (one command)

```bash
git clone git@github.com:aristocr2t/openconnect-proxy-stack.git
cd openconnect-proxy-stack
./deploy.sh
```

On the first run it asks for the VPN credentials and for a username/password pair per protocol
(SOCKS5, HTTP, HTTPS), writes them to `.env` (chmod 600, never committed), then builds the image,
starts the containers, waits until they report healthy and verifies all three proxies.

**Change credentials** (VPN and every protocol): one command, current values are offered as defaults.

```bash
./deploy.sh creds
```

Editing `.env` by hand and running `./deploy.sh` does the same.

**Remove everything** (containers, network, image, volume with the MTProto secret and the VPN pin):

```bash
./deploy.sh remove
```

Other commands: `./deploy.sh status` (containers, ports, recent logs), `./deploy.sh logs` (tail -f).

## Usage

```bash
# SOCKS5 (SOCKS5_USER / SOCKS5_PASS)
curl --socks5-hostname HOST:2085 --proxy-user SOCKS_USER:SOCKS_PASS https://ifconfig.me

# HTTPS CONNECT (HTTPS_USER / HTTPS_PASS)
curl --proxy https://HOST:2443 --proxy-insecure --proxy-user HTTPS_USER:HTTPS_PASS https://ifconfig.me

# HTTP CONNECT (HTTP_USER / HTTP_PASS)
curl --proxy http://HOST:2080 --proxy-user HTTP_USER:HTTP_PASS https://ifconfig.me
```

### MTProto (Telegram)

MTProto has no username/password: the secret *is* the password of the proxy.
Set it in `.env` (`MTPROTO_SECRET`, hex or base64); when empty it is generated on the first run
and stored in the `etc-mtg` volume (`/etc/mtg/mtg.toml`), so it survives redeploys. To read it:

```bash
docker exec proxystack-vpn mtg access /etc/mtg/mtg.toml
```

`mtg access` prints `tg_url` with the *internal* port (8443), so take the secret from it and build
the link with your host port below.

In Telegram: Settings → Advanced → Proxy → MTProto, server = host address, port = `MTPROTO_PORT`,
secret = the `base64` value from the command above. Or use a link:

```
tg://proxy?server=HOST&port=2444&secret=<base64>
```

To rotate the secret, drop the volume and deploy again: `./deploy.sh remove && ./deploy.sh`.

## Architecture

```
 Client ──► host:2085 ──► proxystack-socks5  (socat)
 Client ──► host:2080 ──► proxystack-http    (socat)
 Client ──► host:2443 ──► proxystack-https   (socat)
 Client ──► host:2444 ──► proxystack-mtproto (socat)
 │
 ▼
 │ proxystack-vpn  (openconnect, tun0, NET_ADMIN)
 │   1080  proxy.py    SOCKS5
 │   3128  connect.py  HTTPS CONNECT
 │   3129  connect.py  HTTP CONNECT
 │   8443  mtg         MTProto
 └──► openconnect ──► tun0 ──► VPN server
```

`src/start.sh` is a supervisor: it resolves the VPN server, starts openconnect, waits for `tun0`,
starts all four proxies inside the container, watches them and reconnects the VPN when it drops
(DPD 30s). All proxies share one container, so the relays never need to enter its network namespace.

## Files

```
openconnect-proxy-stack/
├── .env.example          template for credentials and ports
├── deploy.sh             deploy / creds / status / logs / remove
├── docker-compose.yml    proxystack-vpn + 4 socat relays
├── README.md             this file
└── src/
    ├── Dockerfile        Alpine 3.21 + openconnect + python3 + mtg
    ├── start.sh          entrypoint: VPN → proxies → supervisor
    ├── proxy.py          SOCKS5 (with auth)
    ├── connect.py        HTTP/HTTPS CONNECT (TLS optional, with auth)
    └── mtg               MTProto v2.3.0 (static binary, linux/arm64)
```

## Troubleshooting

**socksprotect VPN servers do not answer TLS with SNI.** That is why `start.sh` resolves the
hostname to an IP first and connects to that IP. The server certificate does not match that IP,
so plain openconnect stops at an interactive `Enter 'yes' to accept` (a hang inside a container);
therefore the certificate is pinned by its public key.

The pin never has to be supplied by hand: on the first connection `start.sh` computes `pin-sha256`
from the server and saves it to `/etc/mtg/vpn-pin` inside the `etc-mtg` volume. Further connections
reuse the stored pin.

- switched VPN server → delete the pin, it is detected again on the next start:
  `docker compose exec vpn rm /etc/mtg/vpn-pin`;
- the server rotated its certificate → `certificate verify failed` in the logs, same fix.

**MTProto resets connections immediately.** mtg v2 loads the firehol_level1 blocklist by default,
which contains private ranges (172.16/12), and the relay connects from a Docker bridge IP.
The generated config disables it: `[defense.blocklist] enabled = false`.

**`mtg.toml` is not regenerated after `start.sh` changes.** The config lives in the `etc-mtg`
volume and is only created when missing — remove the volume (`./deploy.sh remove`) and deploy again.

**`docker compose build` fails with `lookup auth.docker.io: no such host`.** Restart Docker Desktop.

**`DTLS handshake failed` in the logs** — openconnect could not establish the UDP tunnel and uses
TLS/TCP instead. Proxies keep working.

**The `src/mtg` binary is built for linux/arm64.** On an x86 host take the linux/amd64 release from
[9seconds/mtg](https://github.com/9seconds/mtg/releases).
