#!/usr/bin/env python3
"""SOCKS5 proxy with optional username/password auth."""

import os
import socket
import struct
import sys
import threading

SOCKS_VERSION = 5
SOCKS5_USER = os.environ.get("SOCKS5_USER", "")
SOCKS5_PASS = os.environ.get("SOCKS5_PASS", "")
AUTH_ENABLED = bool(SOCKS5_USER)

BIND_IP = sys.argv[2] if len(sys.argv) > 2 else "0.0.0.0"
BIND_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 1080


def recv_exact(sock, n):
  buf = b""
  while len(buf) < n:
    chunk = sock.recv(n - len(buf))
    if not chunk:
      raise ConnectionError("connection closed")
    buf += chunk
  return buf


def create_socket():
  return socket.socket(socket.AF_INET, socket.SOCK_STREAM)


def check_auth(client_sock):
  client_sock.settimeout(10)
  ver, ulen = struct.unpack("!BB", recv_exact(client_sock,2))
  if ver != 1:
    return False
  username = recv_exact(client_sock,ulen).decode()
  plen = recv_exact(client_sock,1)[0]
  password = recv_exact(client_sock,plen).decode()
  ok = (username == SOCKS5_USER and password == SOCKS5_PASS)
  client_sock.sendall(struct.pack("!BB", 1, 0 if ok else 1))
  return ok


def do_socks5_handshake(client_sock):
  client_sock.settimeout(30)
  ver, nmethods = struct.unpack("!BB", recv_exact(client_sock,2))
  methods = set(recv_exact(client_sock,nmethods))

  if AUTH_ENABLED:
    # Credentials are configured: never fall back to a no-auth method.
    if 2 not in methods:
      client_sock.sendall(struct.pack("!BB", SOCKS_VERSION, 0xFF))
      return None
    client_sock.sendall(struct.pack("!BB", SOCKS_VERSION, 2))
    if not check_auth(client_sock):
      return None
  elif 0 in methods:
    client_sock.sendall(struct.pack("!BB", SOCKS_VERSION, 0))
  else:
    client_sock.sendall(struct.pack("!BB", SOCKS_VERSION, 0xFF))
    return None

  ver, cmd, rsv, atyp = struct.unpack("!BBBB", recv_exact(client_sock,4))
  if cmd != 1:
    return None

  if atyp == 1:
    addr = socket.inet_ntoa(recv_exact(client_sock,4))
  elif atyp == 3:
    domain_len = recv_exact(client_sock,1)[0]
    addr = recv_exact(client_sock,domain_len).decode()
  elif atyp == 4:
    addr = socket.inet_ntop(socket.AF_INET6, recv_exact(client_sock,16))
  else:
    return None

  port = struct.unpack("!H", recv_exact(client_sock,2))[0]
  return (addr, port)


def handle_client(client_sock):
  try:
    target = do_socks5_handshake(client_sock)
    if target is None:
      client_sock.close()
      return

    addr, port = target
    print(f"[proxy] CONNECT {addr}:{port}", flush=True)

    remote = create_socket()
    remote.settimeout(15)
    remote.connect((addr, port))

    client_sock.sendall(struct.pack("!BBBB", SOCKS_VERSION, 0, 0, 1)
                        + socket.inet_aton("0.0.0.0")
                        + struct.pack("!H", 0))

    # TCP keepalive: a dead or black-holed tunnel must surface as an error
    # instead of leaving the client hanging forever.
    for s in (client_sock, remote):
      s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
      for opt_name, val in (("TCP_KEEPIDLE", 45), ("TCP_KEEPINTVL", 15), ("TCP_KEEPCNT", 4)):
        opt = getattr(socket, opt_name, None)
        if opt is not None:
          try:
            s.setsockopt(socket.IPPROTO_TCP, opt, val)
          except OSError:
            pass

    client_sock.settimeout(None)
    remote.settimeout(None)

    def relay(src, dst):
      try:
        while True:
          data = src.recv(8192)
          if not data:
            break
          dst.sendall(data)
      except Exception:
        pass

    t1 = threading.Thread(target=relay, args=(client_sock, remote), daemon=True)
    t2 = threading.Thread(target=relay, args=(remote, client_sock), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()

  except Exception as e:
    print(f"[proxy] Error: {e}", flush=True)
  finally:
    try:
      client_sock.close()
    except Exception:
      pass


def main():
  mode = "AUTH" if AUTH_ENABLED else "OPEN"
  print(f"[proxy] SOCKS5 ({mode}) starting on {BIND_IP}:{BIND_PORT}", flush=True)
  server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
  server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
  server.bind((BIND_IP, BIND_PORT))
  server.listen(128)
  while True:
    client, addr = server.accept()
    threading.Thread(target=handle_client, args=(client,), daemon=True).start()


if __name__ == "__main__":
  main()
