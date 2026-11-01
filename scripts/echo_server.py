#!/usr/bin/env python3
"""Minimal RFC 6455 echo server (stdlib only) for the B5 round-trip check.  usage: echo_server.py <port>"""
import asyncio
import base64
import hashlib
import struct
import sys

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


async def read_frame(reader):
    h = await reader.readexactly(2)
    op, masked, n = h[0] & 0x0F, h[1] & 0x80, h[1] & 0x7F
    if n == 126:
        n = struct.unpack(">H", await reader.readexactly(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", await reader.readexactly(8))[0]
    key = await reader.readexactly(4) if masked else b"\0\0\0\0"
    data = bytearray(await reader.readexactly(n))
    for i in range(n):
        data[i] ^= key[i % 4]
    return op, bytes(data)


def frame(op, data):
    n = len(data)
    head = bytes([0x80 | op]) + (bytes([n]) if n < 126 else b"\x7e" + struct.pack(">H", n) if n < 65536 else b"\x7f" + struct.pack(">Q", n))
    return head + data


async def handle(reader, writer):
    try:
        req = (await reader.readuntil(b"\r\n\r\n")).decode()
        key = next(l.split(":", 1)[1].strip() for l in req.split("\r\n") if l.lower().startswith("sec-websocket-key"))
        accept = base64.b64encode(hashlib.sha1(key.encode() + GUID).digest()).decode()
        writer.write(f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n".encode())
        await writer.drain()
        while True:
            op, data = await read_frame(reader)
            if op == 8:
                writer.write(frame(8, b""))
                break
            if op == 9:
                writer.write(frame(10, data))
            elif op in (1, 2):
                writer.write(frame(op, data))  # echo
            await writer.drain()
    except (asyncio.IncompleteReadError, ConnectionError):
        pass
    finally:
        writer.close()


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", int(sys.argv[1]))
    print(f"echo on ws://127.0.0.1:{sys.argv[1]}", flush=True)
    async with server:
        await server.serve_forever()


asyncio.run(main())
