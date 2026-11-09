#!/usr/bin/env python3
"""HTTP CONNECT proxy with TLS and optional Basic auth."""

import os, socket, ssl, base64, threading, sys, select

BIND_IP = sys.argv[2] if len(sys.argv) > 2 else "0.0.0.0"
BIND_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 3128
PROXY_USER = sys.argv[3] if len(sys.argv) > 3 else os.environ.get("CONNECT_USER", "")
PROXY_PASS = sys.argv[4] if len(sys.argv) > 4 else os.environ.get("CONNECT_PASS", "")
AUTH = (PROXY_USER + ":" + PROXY_PASS).encode() if PROXY_USER else None
CERT_FILE = os.environ.get("TLS_CERT", "/etc/tls/proxy.pem")
KEY_FILE = os.environ.get("TLS_KEY", "")
USE_TLS = os.environ.get("CONNECT_TLS", "") == "1"


def relay(src, dst):
  try:
    while True:
      r, _, _ = select.select([src], [], [], 300)
      if not r:
        break
      data = src.recv(8192)
      if not data:
        break
      dst.sendall(data)
  except Exception:
    pass


def handle(client):
  remote = None
  try:
    buf = b""
    while b"\r\n\r\n" not in buf:
      chunk = client.recv(4096)
      if not chunk:
        client.close()
        return
      buf += chunk
      if len(buf) > 65536:  # CONNECT headers are tiny; the cap keeps memory bounded
        client.sendall(b"HTTP/1.1 431 Request Header Fields Too Large\r\n\r\n")
        client.close()
        return

    head, rest = buf.split(b"\r\n\r\n", 1)
    lines = head.decode().split("\r\n")
    parts = lines[0].split(" ")
    if len(parts) < 3:
      client.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
      client.close()
      return
    method, target, _ = parts

    if method != "CONNECT":
      client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
      client.close()
      return

    if AUTH:
      authed = False
      for line in lines[1:]:
        if line.lower().startswith("proxy-authorization:"):
          p = line.split(" ", 2)
          if len(p) >= 3 and p[1].lower() == "basic":
            try:
              creds = base64.b64decode(p[2]).decode()
              authed = (creds == PROXY_USER + ":" + PROXY_PASS)
            except Exception:
              pass
      if not authed:
        client.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic\r\n\r\n")
        client.close()
        return

    if ":" not in target:
      client.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
      client.close()
      return

    host, port = target.split(":", 1)
    port = int(port)

    print(f"[connect] CONNECT {host}:{port}", flush=True)
    remote = socket.create_connection((host, port), timeout=15)
    client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")

    if rest:
      remote.sendall(rest)

    t1 = threading.Thread(target=relay, args=(client, remote), daemon=True)
    t2 = threading.Thread(target=relay, args=(remote, client), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()

  except Exception as e:
    print(f"[connect] Error: {e}", flush=True)
  finally:
    try:
      client.close()
    except Exception:
      pass
    if remote:
      try:
        remote.close()
      except Exception:
        pass


def main():
  mode = "TLS+AUTH" if (USE_TLS and AUTH) else ("TLS" if USE_TLS else ("AUTH" if AUTH else "OPEN"))
  print(f"[connect] HTTP CONNECT ({mode}) on {BIND_IP}:{BIND_PORT}", flush=True)

  s = socket.socket()
  s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
  s.bind((BIND_IP, BIND_PORT))
  s.listen(128)

  while True:
    client, addr = s.accept()
    if USE_TLS:
      ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
      cert = KEY_FILE if KEY_FILE and os.path.isfile(KEY_FILE) else CERT_FILE
      ctx.load_cert_chain(cert)
      try:
        client = ctx.wrap_socket(client, server_side=True)
      except Exception as e:
        print(f"[connect] TLS error: {e}", flush=True)
        try:
          client.close()
        except Exception:
          pass
        continue
    threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
  main()
