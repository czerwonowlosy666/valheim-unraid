#!/usr/bin/env python3
"""A tiny fake Thunderstore API for testing thunderstore.py offline.

GET  /api/experimental/package/<ns>/<name>/            latest package
GET  /api/experimental/package/<ns>/<name>/<ver>/      one version
GET  /package/download/<ns>/<name>/<ver>/              zip
GET  /api/experimental/legacyprofile/get/<code>/       r2modman profile
POST /_release/<ns>/<name>/<ver>                       publish a new version
"""
import base64
import io
import json
import sys
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
BASE = f"http://127.0.0.1:{PORT}"


def zbytes(files):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for name, data in files.items():
            z.writestr(name, data)
    return buf.getvalue()


def manifest(name, ver, deps):
    return json.dumps({"name": name, "version_number": ver, "dependencies": deps})


# packages[(ns, name)] = {version: (dependencies, files)}
packages = {
    ("denikson", "BepInExPack_Valheim"): {
        "5.4.2333": ([], {
            "manifest.json": manifest("BepInExPack_Valheim", "5.4.2333", []),
            "icon.png": "png",
            "BepInExPack_Valheim/BepInEx/core/BepInEx.Preloader.dll": "core",
            "BepInExPack_Valheim/BepInEx/config/BepInEx.cfg": "[Logging]\ndefault",
            "BepInExPack_Valheim/libdoorstop.so": "elf",
            "BepInExPack_Valheim/doorstop_config.ini": "ini",
            "BepInExPack_Valheim/start_server_bepinex.sh": "#!/bin/sh\n",
        }),
    },
    ("ValheimModding", "Jotunn"): {
        "2.20.0": (["denikson-BepInExPack_Valheim-5.4.2202"], {
            "manifest.json": manifest("Jotunn", "2.20.0", []),
            "plugins/Jotunn.dll": "jotunn-2.20.0",
        }),
    },
    ("Azumatt", "AzuCraftyBoxes"): {
        "1.5.0": (["denikson-BepInExPack_Valheim-5.4.2202", "ValheimModding-Jotunn-2.12.0"], {
            "manifest.json": manifest("AzuCraftyBoxes", "1.5.0", []),
            "plugins\\AzuCraftyBoxes.dll": "acb",           # Windows-style path, as some uploads have
            "config\\Azumatt.AzuCraftyBoxes.cfg": "from-zip",
        }),
    },
    ("Smoothbrain", "ServerCharacters"): {
        "1.4.0": ([], {"ServerCharacters.dll": "sc-1.4.0"}),
        "1.5.0": ([], {"ServerCharacters.dll": "sc-1.5.0"}),
    },
    ("Nested", "PatcherMod"): {
        "1.0.0": ([], {
            "BepInEx/plugins/PatcherMod/PatcherMod.dll": "p",
            "BepInEx/patchers/PatcherMod.Patch.dll": "patch",
        }),
    },
    ("RandyKnapp", "EquipmentAndQuickSlots"): {
        "2.1.15": ([], {"EquipmentAndQuickSlots.dll": "eaqs"}),
    },
}


def latest(ns, name):
    versions = packages[(ns, name)]
    return max(versions, key=lambda v: tuple(int(x) for x in v.split(".")))


def version_obj(ns, name, ver):
    deps, _ = packages[(ns, name)][ver]
    return {
        "namespace": ns, "name": name, "version_number": ver,
        "full_name": f"{ns}-{name}-{ver}", "dependencies": deps,
        "download_url": f"{BASE}/package/download/{ns}/{name}/{ver}/",
    }


def find(ns, name):
    for (n, m) in packages:
        if n.lower() == ns.lower() and m.lower() == name.lower():
            return n, m
    return None


def profile_payload():
    export = (
        "profileName: Friends\n"
        "mods:\n"
        "  - name: denikson-BepInExPack_Valheim\n    version: {major: 5, minor: 4, patch: 2333}\n    enabled: true\n"
        "  - name: Smoothbrain-ServerCharacters\n    version: {major: 1, minor: 4, patch: 0}\n    enabled: true\n"
        "  - name: RandyKnapp-EquipmentAndQuickSlots\n    version: {major: 2, minor: 1, patch: 15}\n    enabled: true\n"
        "  - name: Nested-PatcherMod\n    version: {major: 1, minor: 0, patch: 0}\n    enabled: false\n"
    )
    z = zbytes({"export.r2x": export, "config/Smoothbrain.ServerCharacters.cfg": "from-profile",
                "config/evil.dll": "nope"})
    return "#r2modman\n" + base64.b64encode(z).decode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parts = [p for p in self.path.split("/") if p]
        try:
            if parts[:3] == ["api", "experimental", "package"]:
                key = find(parts[3], parts[4])
                if not key:
                    return self.send(404, '{"detail":"Not found."}')
                if len(parts) == 6:
                    if parts[5] not in packages[key]:
                        return self.send(404, '{"detail":"Not found."}')
                    return self.send(200, json.dumps(version_obj(*key, parts[5])))
                body = {"namespace": key[0], "name": key[1], "is_deprecated": False,
                        "latest": version_obj(*key, latest(*key))}
                return self.send(200, json.dumps(body))
            if parts[:2] == ["package", "download"]:
                key = find(parts[2], parts[3])
                _, files = packages[key][parts[4]]
                return self.send(200, zbytes(files), "application/zip")
            if parts[:4] == ["api", "experimental", "legacyprofile", "get"]:
                if parts[4] == "good-code":
                    return self.send(200, profile_payload(), "text/plain")
                return self.send(404, '{"detail":"Not found."}')
        except Exception as e:  # pragma: no cover
            return self.send(500, str(e))
        self.send(404, "{}")

    def do_POST(self):
        parts = [p for p in self.path.split("/") if p]
        if parts[0] == "_release":
            key = find(parts[1], parts[2])
            deps, files = packages[key][latest(*key)]
            files = {k: (v + "-" + parts[3] if k.endswith(".dll") else v) for k, v in files.items()}
            packages[key][parts[3]] = (deps, files)
            return self.send(200, "{}")
        self.send(404, "{}")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
