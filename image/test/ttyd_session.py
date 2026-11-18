#!/usr/bin/env python3
"""Drive one ttyd terminal through the gate, the way the browser client does.

Used by acceptance.sh. Standard library only, so it runs on any test host.

  1. GET <path>/token with the session cookie, as the client does before it
     opens the socket (ttyd 1.7.7 html/src/components/app.tsx).
  2. Open <path>/ws with subprotocol "tty", the cookie, and a foreign Origin.
  3. Send the client's first message, JSON {AuthToken, columns, rows}, which is
     what makes ttyd spawn the shell.
  4. Type the command lines given on stdin, each as an INPUT ('0') message.
  5. Collect OUTPUT ('0') messages until --until appears, then print them.

Exit status: 0 when --until was seen, 3 when the handshake was refused (the
response status line goes to stderr), 4 on timeout (what arrived goes to stdout
anyway, so the caller can show it).

  --hold N   keep the socket open N seconds after --until, for the idle
             watchdog check.
"""

import argparse
import base64
import hashlib
import http.client
import json
import os
import socket
import struct
import sys
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def send_frame(sock, payload, opcode=0x2):
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([0x80 | n])
    elif n < 65536:
        header += bytes([0x80 | 126]) + struct.pack("!H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack("!Q", n)
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(header + mask + masked)


def recv_exact(sock, n, buf):
    while len(buf) < n:
        chunk = sock.recv(65536)
        if not chunk:
            raise EOFError
        buf += chunk
    return buf[:n], buf[n:]


def recv_frame(sock, buf):
    head, buf = recv_exact(sock, 2, buf)
    opcode = head[0] & 0x0F
    n = head[1] & 0x7F
    if n == 126:
        ext, buf = recv_exact(sock, 2, buf)
        n = struct.unpack("!H", ext)[0]
    elif n == 127:
        ext, buf = recv_exact(sock, 8, buf)
        n = struct.unpack("!Q", ext)[0]
    if head[1] & 0x80:
        _, buf = recv_exact(sock, 4, buf)  # servers do not mask; tolerate it
    payload, buf = recv_exact(sock, n, buf)
    return opcode, payload, buf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--cookie", default="")
    ap.add_argument("--path", default="", help="the prefix the client derives, '' at the root")
    ap.add_argument("--origin", default="https://ondemand.example.org")
    ap.add_argument("--until", required=True)
    ap.add_argument("--timeout", type=float, default=30)
    ap.add_argument("--hold", type=float, default=0)
    args = ap.parse_args()

    headers = {"Cookie": args.cookie} if args.cookie else {}

    token = ""
    conn = http.client.HTTPConnection("127.0.0.1", args.port, timeout=10)
    conn.request("GET", args.path + "/token", headers=headers)
    resp = conn.getresponse()
    body = resp.read()
    conn.close()
    if resp.status == 200:
        try:
            token = json.loads(body.decode()).get("token", "")
        except ValueError:
            pass

    key = base64.b64encode(os.urandom(16)).decode()
    sock = socket.create_connection(("127.0.0.1", args.port), timeout=args.timeout)
    lines = [
        "GET %s/ws HTTP/1.1" % args.path,
        "Host: 127.0.0.1:%d" % args.port,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: %s" % key,
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Protocol: tty",
        "Origin: %s" % args.origin,
    ]
    if args.cookie:
        lines.append("Cookie: %s" % args.cookie)
    sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())

    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            break
        buf += chunk
    head, _, buf = buf.partition(b"\r\n\r\n")
    status = head.split(b"\r\n", 1)[0].decode("latin-1", "replace")
    if " 101 " not in status + " ":
        print(status, file=sys.stderr)
        return 3
    want = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    if ("sec-websocket-accept: " + want.lower()) not in head.decode("latin-1").lower():
        print("bad Sec-WebSocket-Accept", file=sys.stderr)
        return 3

    send_frame(sock, json.dumps({"AuthToken": token, "columns": 160, "rows": 50}).encode())
    for line in sys.stdin.read().splitlines():
        send_frame(sock, b"0" + line.encode() + b"\r")

    out = b""
    deadline = time.time() + args.timeout
    seen = False
    try:
        while time.time() < deadline:
            sock.settimeout(max(0.1, deadline - time.time()))
            opcode, payload, buf = recv_frame(sock, buf)
            if opcode == 0x8:
                break
            if opcode == 0x9:
                send_frame(sock, payload, opcode=0xA)
                continue
            if opcode in (0x1, 0x2) and payload[:1] == b"0":
                out += payload[1:]
                if args.until.encode() in out:
                    seen = True
                    break
    except (socket.timeout, EOFError, OSError):
        pass

    sys.stdout.write(out.decode("utf-8", "replace").replace("\r", ""))
    sys.stdout.flush()
    if seen and args.hold > 0:
        # Stay a well-behaved client while holding: ttyd pings every 5s
        # (-P default) and libwebsockets hangs up on a client that does not
        # answer, which would make the watchdog check fail for the wrong reason.
        until = time.time() + args.hold
        try:
            while time.time() < until:
                sock.settimeout(max(0.1, until - time.time()))
                try:
                    opcode, payload, buf = recv_frame(sock, buf)
                except socket.timeout:
                    break
                if opcode == 0x9:
                    send_frame(sock, payload, opcode=0xA)
                elif opcode == 0x8:
                    break
        except (EOFError, OSError):
            pass
    try:
        send_frame(sock, b"", opcode=0x8)
        sock.close()
    except OSError:
        pass
    return 0 if seen else 4


if __name__ == "__main__":
    sys.exit(main())
