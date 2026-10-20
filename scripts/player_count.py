#!/usr/bin/env python3
"""Print the number of connected players using a Steam A2S_INFO query.

Valheim answers A2S queries on its query port (game port + 1).
Exit code 1 (and no output) if the server did not answer.
Usage: player_count.py [host] [query_port]
"""
import socket
import struct
import sys

HEADER = b"\xFF\xFF\xFF\xFF"
REQUEST = HEADER + b"TSource Engine Query\x00"


def query(host, port, timeout=3.0):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(timeout)
        s.sendto(REQUEST, (host, port))
        data, _ = s.recvfrom(4096)
        if data[4:5] == b"A":  # challenge: repeat the request with it appended
            s.sendto(REQUEST + data[5:9], (host, port))
            data, _ = s.recvfrom(4096)
    if data[:4] != HEADER or data[4:5] != b"I":
        raise ValueError("unexpected A2S reply")
    pos = 6  # header, type byte, protocol byte
    for _ in range(4):  # name, map, folder, game
        pos = data.index(b"\x00", pos) + 1
    pos += 2  # app id (short)
    return data[pos]


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 2457
    for _ in range(3):
        try:
            print(query(host, port))
            return 0
        except (OSError, ValueError, IndexError, struct.error):
            continue
    return 1


if __name__ == "__main__":
    sys.exit(main())
