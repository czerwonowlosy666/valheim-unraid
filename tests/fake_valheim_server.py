#!/usr/bin/env python3
"""Stand-in for valheim_server.x86_64 used by the integration test.
Logs its arguments and environment, answers A2S queries with the player count
in $FAKE_STATE/players, and "saves" on SIGINT like the real server."""
import os, signal, socket, sys, threading, time

state = os.environ.get("FAKE_STATE", "/tmp/fake")
os.makedirs(state, exist_ok=True)
args = sys.argv[1:]
port = int(args[args.index("-port") + 1]) if "-port" in args else 2456

if os.path.exists(os.path.join(state, "crash")):
    print("Fake server crashing on purpose", flush=True)
    sys.exit(3)

with open(os.path.join(state, "args"), "w") as f:
    f.write("\n".join(args))
with open(os.path.join(state, "env"), "w") as f:
    for k in sorted(os.environ):
        if k.startswith(("DOORSTOP", "LD_", "SteamAppId")):
            f.write(f"{k}={os.environ[k]}\n")
with open(os.path.join(state, "starts"), "a") as f:
    f.write(f"{time.time()}\n")

def a2s():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", port + 1))
    while True:
        data, addr = s.recvfrom(1400)
        if not data.startswith(b"\xff\xff\xff\xffTSource Engine Query\x00"):
            continue
        if len(data) == 25:  # no challenge yet
            s.sendto(b"\xff\xff\xff\xffA" + b"\x01\x02\x03\x04", addr)
            continue
        try:
            players = int(open(os.path.join(state, "players")).read().strip())
        except Exception:
            players = 0
        body = b"\xff\xff\xff\xffI\x11" + b"Fake\x00" + b"map\x00" + b"valheim\x00" + b"Valheim\x00" + b"\x00\x00" + bytes([players, 10, 0])
        s.sendto(body, addr)

threading.Thread(target=a2s, daemon=True).start()

def on_int(*_):
    print("Saving world...", flush=True)
    open(os.path.join(state, "saved"), "a").write(f"{time.time()}\n")
    if "-savedir" in args and "-world" in args:
        wdir = os.path.join(args[args.index("-savedir") + 1], "worlds_local", args[args.index("-world") + 1])
        os.makedirs(wdir, exist_ok=True)
        open(os.path.join(wdir, "_main.0.db"), "w").write("world data")
    time.sleep(1)
    print("World saved, bye", flush=True)
    sys.exit(0)

signal.signal(signal.SIGINT, on_int)
print("Fake Valheim server started", flush=True)
print("", flush=True)
print("(Filename: ./Runtime/Export/Debug/Debug.bindings.h Line: 35)", flush=True)
print(f"Game server connected (port {port})", flush=True)
while True:
    time.sleep(0.5)
