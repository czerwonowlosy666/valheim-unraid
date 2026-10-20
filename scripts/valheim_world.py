#!/usr/bin/env python3
"""Create and inspect Valheim world metadata so a dedicated server can start
from a chosen seed.

Valheim's dedicated server has no seed launch flag. It does, however, load a
world from its metadata file alone: if `<savedir>/worlds_local/<World>/` holds
only `_main.0.fwl2`, the server generates the terrain from the seed inside it.

The binary layout is ported from MakeFwl 4.0.0 by Crystal Ferrai
(https://github.com/CrystalFerrai/MakeFwl, Apache-2.0), which follows
World.SaveWorldMetaData in assembly_valheim for Valheim 1.0.

Usage:
  valheim_world.py create --savedir DIR --name NAME --seed SEED [--world-version N]
  valheim_world.py read FILE
  valheim_world.py find --savedir DIR --name NAME   (prints the world's seed, exit 1 if none)
  valheim_world.py exists --savedir DIR --name NAME (exit 0 if the world exists)
  valheim_world.py hash SEED
"""
import argparse
import io
import os
import random
import struct
import sys

WORLD_VERSION = 41      # Version.c_WorldVersion as of Valheim 1.0
WORLDGEN_VERSION = 2    # Version.World enum
META_FILE = "_main.0.fwl2"
SEED_CHARS = "abcdefghijklmnpqrstuvwxyzABCDEFGHIJKLMNPQRSTUVWXYZ023456789"


def _i32(value):
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value & 0x80000000 else value


def stable_hash(text):
    """Port of StringExtensionMethods.GetStableHashCode (32-bit wrapping)."""
    a = b = 5381
    i = 0
    while i < len(text) and text[i] != "\0":
        a = _i32(((a << 5) + a) ^ ord(text[i]))
        if i == len(text) - 1 or text[i + 1] == "\0":
            break
        b = _i32(((b << 5) + b) ^ ord(text[i + 1]))
        i += 2
    return _i32(a + b * 1566083941)


def _write_string(buf, text):
    """C# BinaryWriter.Write(string): 7-bit encoded byte length, then bytes."""
    data = text.encode("ascii")
    n = len(data)
    while True:
        byte = n & 0x7F
        n >>= 7
        buf.write(bytes([byte | (0x80 if n else 0)]))
        if not n:
            break
    buf.write(data)


def _read_string(buf):
    n, shift = 0, 0
    while True:
        byte = buf.read(1)[0]
        n |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            break
    return buf.read(n).decode("utf-8", errors="replace")


def validate(name, seed):
    errors = []
    if not name or not name.isascii() or any(c in name for c in '/\\:*?"<>|'):
        errors.append("World name must be plain ASCII without / \\ : * ? \" < > |")
    if seed is not None:
        if not 1 <= len(seed) <= 10:
            errors.append("Seed must be 1-10 characters (Valheim's limit)")
        if not seed.isascii() or not seed.isprintable() or " " in seed:
            errors.append("Seed must be ASCII letters, numbers or symbols without spaces")
    return errors


def build_metadata(name, seed, world_version=WORLD_VERSION):
    body = io.BytesIO()
    body.write(struct.pack("<i", world_version))
    _write_string(body, name)
    _write_string(body, seed)
    body.write(struct.pack("<i", stable_hash(seed)))
    uid = _i32(stable_hash(name)) + random.randint(1, 2**31 - 1) + random.randint(0, 2**31 - 1)
    body.write(struct.pack("<q", uid))
    body.write(struct.pack("<i", WORLDGEN_VERSION))
    body.write(struct.pack("<?", False))   # m_needsDB: world can load without a .db
    body.write(struct.pack("<i", 0))       # starting global keys (modifiers are passed as launch flags instead)
    body.write(struct.pack("<i", 0))       # player history count
    data = body.getvalue()
    return struct.pack("<i", len(data)) + data


def parse_metadata(raw):
    buf = io.BytesIO(raw)
    (size,) = struct.unpack("<i", buf.read(4))
    if size <= 0 or size > len(raw) - 4:
        raise ValueError("not a Valheim world metadata file")
    (version,) = struct.unpack("<i", buf.read(4))
    name = _read_string(buf)
    seed_name = _read_string(buf)
    (seed,) = struct.unpack("<i", buf.read(4))
    return {"version": version, "name": name, "seed_name": seed_name, "seed": seed}


def world_paths(savedir, name):
    """Return (new-format folder, legacy .fwl path)."""
    new_dir = os.path.join(savedir, "worlds_local", name)
    legacy = [os.path.join(savedir, d, name + ".fwl") for d in ("worlds_local", "worlds")]
    return new_dir, legacy


def find_world(savedir, name):
    new_dir, legacy = world_paths(savedir, name)
    candidates = [os.path.join(new_dir, META_FILE)] + legacy
    for path in candidates:
        if os.path.isfile(path):
            return path
    if os.path.isdir(new_dir):
        # Any metadata chunk in the world folder (the game may number them).
        for entry in sorted(os.listdir(new_dir)):
            if entry.endswith(".fwl2"):
                return os.path.join(new_dir, entry)
    return None


def world_exists(savedir, name):
    new_dir, legacy = world_paths(savedir, name)
    if os.path.isdir(new_dir) and os.listdir(new_dir):
        return True
    for fwl in legacy:
        if os.path.exists(fwl) or os.path.exists(fwl[:-4] + ".db"):
            return True
    return False


def cmd_create(args):
    errors = validate(args.name, args.seed)
    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        return 2
    if world_exists(args.savedir, args.name):
        print(f"World '{args.name}' already exists; not touching it.", file=sys.stderr)
        return 3
    new_dir, _ = world_paths(args.savedir, args.name)
    os.makedirs(new_dir, exist_ok=True)
    path = os.path.join(new_dir, META_FILE)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(build_metadata(args.name, args.seed, args.world_version))
    os.replace(tmp, path)
    print(f"Created world '{args.name}' with seed '{args.seed}' ({stable_hash(args.seed)}) at {path}")
    return 0


def cmd_read(args):
    with open(args.file, "rb") as f:
        meta = parse_metadata(f.read())
    for key, value in meta.items():
        print(f"{key}={value}")
    return 0


def cmd_find(args):
    path = find_world(args.savedir, args.name)
    if not path:
        return 1
    try:
        with open(path, "rb") as f:
            meta = parse_metadata(f.read())
    except (OSError, ValueError, IndexError, struct.error):
        return 1
    print(meta["seed_name"])
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("create")
    p.add_argument("--savedir", required=True)
    p.add_argument("--name", required=True)
    p.add_argument("--seed")
    p.add_argument("--world-version", type=int, default=WORLD_VERSION)
    p = sub.add_parser("read")
    p.add_argument("file")
    p = sub.add_parser("find")
    p.add_argument("--savedir", required=True)
    p.add_argument("--name", required=True)
    p = sub.add_parser("exists")
    p.add_argument("--savedir", required=True)
    p.add_argument("--name", required=True)
    p = sub.add_parser("hash")
    p.add_argument("seed")
    args = parser.parse_args()

    if args.cmd == "create":
        if not args.seed:
            args.seed = "".join(random.choice(SEED_CHARS) for _ in range(10))
        return cmd_create(args)
    if args.cmd == "read":
        return cmd_read(args)
    if args.cmd == "find":
        return cmd_find(args)
    if args.cmd == "exists":
        return 0 if world_exists(args.savedir, args.name) else 1
    print(stable_hash(args.seed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
