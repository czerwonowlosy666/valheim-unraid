#!/usr/bin/env python3
"""Thunderstore mod manager for a Valheim dedicated server.

Reads the wanted mods from environment variables, resolves dependencies through
the Thunderstore API, and installs BepInEx plus every mod into the server
folder the same way r2modman lays them out.

Commands:
  sync    install, update and remove mods so the server matches the wanted list
  check   exit 10 if anything would change (an update is available), 0 if not
  list    show installed mods

Environment:
  MODS                       Mods to install, separated by commas, spaces or new lines.
                             Accepts Author-Name, Author-Name-1.2.3 (pinned) or
                             Thunderstore page URLs.
  MODS_EXCLUDE               Mods to never install (e.g. client-only mods from a profile).
  THUNDERSTORE_PROFILE_CODE  r2modman / Thunderstore Mod Manager profile code to import.
  PROFILE_PIN_VERSIONS       true = keep the exact versions in the profile (no auto-update).
  PROFILE_IMPORT_CONFIGS     true = copy the profile's config files (only files you don't have yet).
  BEPINEX_ENABLED            true = install BepInEx even with no mods (for custom plugins).
  THUNDERSTORE_URL           API base, default https://thunderstore.io
"""
import argparse
import base64
import io
import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

try:
    import yaml
except ImportError:  # only needed for profile codes
    yaml = None

BEPINEX_PACK = "denikson-BepInExPack_Valheim"
UPDATE_AVAILABLE = 10
CONFIG_EXTENSIONS = (".cfg", ".txt", ".json", ".yml", ".yaml", ".ini")
DOC_FILES = {"manifest.json", "icon.png", "readme.md", "changelog.md", "license", "license.md", "license.txt"}
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
URL_RE = re.compile(r"thunderstore\.io/(?:c/[^/]+/p|package)/([^/]+)/([^/]+)(?:/v/([^/]+))?", re.I)

BASE_URL = os.environ.get("THUNDERSTORE_URL", "https://thunderstore.io").rstrip("/")
USER_AGENT = "valheim-unraid/1.0 (+https://github.com)"


def log(msg):
    print(f"[mods] {msg}", flush=True)


def truthy(value, default=False):
    if value is None or value == "":
        return default
    return str(value).strip().lower() in ("1", "true", "yes", "on")


# --------------------------------------------------------------------------- API

def http_get(url, binary=False, retries=3):
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = resp.read()
            return data if binary else data.decode("utf-8")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise
            last = e
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            last = e
        time.sleep(2 * (attempt + 1))
    raise last


class Api:
    def __init__(self):
        self.cache = {}

    def package(self, ns, name, version=None):
        """Return dict with full_name, namespace, name, version, dependencies, download_url."""
        key = (ns.lower(), name.lower(), version)
        if key in self.cache:
            return self.cache[key]
        if version:
            url = f"{BASE_URL}/api/experimental/package/{ns}/{name}/{version}/"
            data = json.loads(http_get(url))
            info = data
        else:
            url = f"{BASE_URL}/api/experimental/package/{ns}/{name}/"
            data = json.loads(http_get(url))
            info = data["latest"]
            if data.get("is_deprecated"):
                log(f"WARNING: {ns}-{name} is marked deprecated on Thunderstore")
        result = {
            "namespace": info.get("namespace") or ns,
            "name": info.get("name") or name,
            "version": info["version_number"],
            "dependencies": info.get("dependencies") or [],
            "download_url": info.get("download_url")
            or f"{BASE_URL}/package/download/{ns}/{name}/{info['version_number']}/",
        }
        result["id"] = f"{result['namespace']}-{result['name']}"
        self.cache[key] = result
        return result


# --------------------------------------------------------------------- wanted list

def parse_spec(text):
    """Return (namespace, name, version-or-None) or None if unparseable."""
    text = text.strip().strip("/")
    if not text:
        return None
    m = URL_RE.search(text)
    if m:
        return m.group(1), m.group(2), m.group(3)
    text = text.replace("/", "-")
    parts = text.split("-")
    if len(parts) >= 3 and VERSION_RE.match(parts[-1]):
        return parts[0], "-".join(parts[1:-1]), parts[-1]
    if len(parts) >= 2:
        return parts[0], "-".join(parts[1:]), None
    return None


def split_list(value):
    return [s for s in re.split(r"[\s,;]+", value or "") if s.strip()]


def mod_key(ns, name):
    return f"{ns}-{name}".lower()


def load_profile(code, cache_dir):
    """Download (or reuse a cached copy of) an r2modman profile.
    Returns (list of (ns, name, version), zipfile bytes)."""
    code = code.strip()
    cached = os.path.join(cache_dir, f"profile-{re.sub(r'[^A-Za-z0-9-]', '_', code)}.zip")
    raw = None
    try:
        text = http_get(f"{BASE_URL}/api/experimental/legacyprofile/get/{code}/")
        if not text.startswith("#r2modman"):
            raise ValueError("response is not an r2modman profile")
        raw = base64.b64decode(text[len("#r2modman"):].strip())
        os.makedirs(cache_dir, exist_ok=True)
        with open(cached, "wb") as f:
            f.write(raw)
    except Exception as e:  # codes expire; fall back to the copy we saved
        if os.path.exists(cached):
            log(f"Profile code {code} could not be fetched ({e}); using the saved copy")
            with open(cached, "rb") as f:
                raw = f.read()
        else:
            raise RuntimeError(f"Could not fetch profile code {code}: {e}")
    if yaml is None:
        raise RuntimeError("python3-yaml is required for profile codes")
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        export = yaml.safe_load(z.read("export.r2x"))
    mods = []
    for m in export.get("mods") or []:
        if not m.get("enabled", True):
            continue
        spec = parse_spec(m["name"])
        if not spec:
            continue
        v = m.get("version") or {}
        version = f"{v.get('major', 0)}.{v.get('minor', 0)}.{v.get('patch', 0)}" if v else None
        mods.append((spec[0], spec[1], version))
    log(f"Profile '{export.get('profileName', code)}': {len(mods)} enabled mods")
    return mods, raw


def wanted_specs(cache_dir):
    """Combine MODS, the profile code and BepInEx into (ns, name, version, pinned) entries."""
    specs = []
    for item in split_list(os.environ.get("MODS")):
        spec = parse_spec(item)
        if spec:
            specs.append((spec[0], spec[1], spec[2], spec[2] is not None))
        else:
            log(f"WARNING: can't understand mod '{item}', expected Author-ModName")

    profile_zip = None
    code = os.environ.get("THUNDERSTORE_PROFILE_CODE", "").strip()
    if code:
        pin = truthy(os.environ.get("PROFILE_PIN_VERSIONS"))
        mods, profile_zip = load_profile(code, cache_dir)
        explicit = {mod_key(s[0], s[1]) for s in specs}
        for ns, name, version in mods:
            if mod_key(ns, name) not in explicit:
                specs.append((ns, name, version if pin else None, pin))

    if specs or truthy(os.environ.get("BEPINEX_ENABLED")):
        if not any(mod_key(s[0], s[1]) == BEPINEX_PACK.lower() for s in specs):
            ns, name = BEPINEX_PACK.split("-", 1)
            specs.insert(0, (ns, name, None, False))
    return specs, profile_zip


def resolve(api, specs, excluded):
    """Resolve the full set of packages, including dependencies.
    Explicitly pinned versions win; everything else uses the latest release."""
    pins = {mod_key(ns, n): v for ns, n, v, pinned in specs if pinned}
    resolved, errors = {}, []
    queue = [(ns, n, pins.get(mod_key(ns, n)), "wanted") for ns, n, _v, _p in specs]
    while queue:
        ns, name, version, why = queue.pop(0)
        key = mod_key(ns, name)
        if key in resolved:
            continue
        if key in excluded:
            if why != "wanted":
                log(f"Skipping {ns}-{name} (excluded; needed by {why})")
            continue
        try:
            pkg = api.package(ns, name, version)
        except urllib.error.HTTPError as e:
            errors.append(f"{ns}-{name}{'-' + version if version else ''}: not found on Thunderstore (HTTP {e.code})")
            continue
        except Exception as e:
            errors.append(f"{ns}-{name}: {e}")
            continue
        resolved[key] = pkg
        for dep in pkg["dependencies"]:
            spec = parse_spec(dep)
            if spec:
                dkey = mod_key(spec[0], spec[1])
                queue.append((spec[0], spec[1], pins.get(dkey), pkg["id"]))
    return resolved, errors


# ------------------------------------------------------------------- installation

class Installer:
    def __init__(self, server_dir, state_file):
        self.server_dir = server_dir
        self.bepinex = os.path.join(server_dir, "BepInEx")
        self.state_file = state_file
        self.state = {"mods": {}}
        if os.path.exists(state_file):
            with open(state_file) as f:
                self.state = json.load(f)

    def save(self):
        os.makedirs(os.path.dirname(self.state_file), exist_ok=True)
        tmp = self.state_file + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.state, f, indent=2, sort_keys=True)
        os.replace(tmp, self.state_file)

    def installed(self):
        return self.state.setdefault("mods", {})

    def is_current(self, key, pkg):
        cur = self.installed().get(key)
        return (
            cur is not None
            and cur.get("version") == pkg["version"]
            and all(os.path.exists(os.path.join(self.server_dir, p)) for p in cur.get("paths", []))
        )

    # -- helpers
    @staticmethod
    def _extract(data, dest):
        """Extract a zip safely, normalising Windows backslash paths."""
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for info in z.infolist():
                name = info.filename.replace("\\", "/")
                if name.endswith("/"):
                    continue
                target = os.path.normpath(os.path.join(dest, name))
                if not target.startswith(os.path.abspath(dest) + os.sep):
                    raise ValueError(f"unsafe path in zip: {info.filename}")
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with z.open(info) as src, open(target, "wb") as out:
                    shutil.copyfileobj(src, out)

    @staticmethod
    def _merge(src, dst, overwrite=True):
        for root, _dirs, files in os.walk(src):
            rel = os.path.relpath(root, src)
            out_dir = os.path.normpath(os.path.join(dst, rel))
            os.makedirs(out_dir, exist_ok=True)
            for f in files:
                target = os.path.join(out_dir, f)
                if overwrite or not os.path.exists(target):
                    shutil.copy2(os.path.join(root, f), target)

    def _remove_paths(self, paths):
        for rel in paths:
            path = os.path.join(self.server_dir, rel)
            if os.path.islink(path) or os.path.isfile(path):
                os.remove(path)
            elif os.path.isdir(path):
                shutil.rmtree(path)

    # -- installs
    def install_bepinex(self, pkg, data):
        with tempfile.TemporaryDirectory() as tmp:
            self._extract(data, tmp)
            root = None
            for dirpath, dirnames, _ in os.walk(tmp):
                if "BepInEx" in dirnames and os.path.isdir(os.path.join(dirpath, "BepInEx", "core")):
                    root = dirpath
                    break
            if not root:
                raise RuntimeError("BepInExPack zip has no BepInEx/core folder")
            paths = []
            for entry in os.listdir(root):
                src = os.path.join(root, entry)
                if entry == "BepInEx":
                    for sub in os.listdir(src):
                        dst = os.path.join(self.bepinex, sub)
                        if sub in ("config", "plugins", "patchers"):
                            self._merge(os.path.join(src, sub), dst, overwrite=False)
                        else:
                            if os.path.isdir(dst):
                                shutil.rmtree(dst)
                            if os.path.isdir(os.path.join(src, sub)):
                                shutil.copytree(os.path.join(src, sub), dst)
                            else:
                                shutil.copy2(os.path.join(src, sub), dst)
                            paths.append(f"BepInEx/{sub}")
                    continue
                dst = os.path.join(self.server_dir, entry)
                if os.path.isdir(src):
                    if os.path.isdir(dst):
                        shutil.rmtree(dst)
                    shutil.copytree(src, dst)
                else:
                    shutil.copy2(src, dst)
                    if entry.endswith(".sh"):
                        os.chmod(dst, 0o755)
                paths.append(entry)
            return paths

    def install_mod(self, pkg, data):
        mod_id = pkg["id"]
        plugins = os.path.join(self.bepinex, "plugins", mod_id)
        paths = {f"BepInEx/plugins/{mod_id}"}
        with tempfile.TemporaryDirectory() as tmp:
            self._extract(data, tmp)
            if os.path.isdir(plugins):
                shutil.rmtree(plugins)
            os.makedirs(plugins)

            def place(src, entry):
                lower = entry.lower()
                if lower in ("plugins",):
                    self._merge(src, plugins)
                elif lower in ("patchers", "monomod"):
                    dst = os.path.join(self.bepinex, lower, mod_id)
                    if os.path.isdir(dst):
                        shutil.rmtree(dst)
                    self._merge(src, dst)
                    paths.add(f"BepInEx/{lower}/{mod_id}")
                elif lower == "config":
                    self._merge(src, os.path.join(self.bepinex, "config"), overwrite=False)
                elif lower == "core":
                    log(f"WARNING: {mod_id} ships BepInEx/core files; ignored")
                elif os.path.isdir(src):
                    self._merge(src, os.path.join(plugins, entry))
                else:
                    shutil.copy2(src, os.path.join(plugins, entry))

            for entry in os.listdir(tmp):
                src = os.path.join(tmp, entry)
                if entry.lower() == "bepinex" and os.path.isdir(src):
                    for sub in os.listdir(src):
                        place(os.path.join(src, sub), sub)
                else:
                    place(src, entry)
        return sorted(paths)

    def install(self, key, pkg):
        data = http_get(pkg["download_url"], binary=True)
        if not zipfile.is_zipfile(io.BytesIO(data)):
            raise RuntimeError("download is not a zip file")
        old = self.installed().get(key)
        if old and key != BEPINEX_PACK.lower():
            self._remove_paths(old.get("paths", []))
        if key == BEPINEX_PACK.lower():
            paths = self.install_bepinex(pkg, data)
        else:
            paths = self.install_mod(pkg, data)
        self.installed()[key] = {"id": pkg["id"], "version": pkg["version"], "paths": paths}
        self.save()

    def remove(self, key):
        cur = self.installed().pop(key, None)
        if cur:
            self._remove_paths(cur.get("paths", []))
            self.save()
        return cur


def import_profile_configs(profile_zip, server_dir, cache_dir):
    marker = os.path.join(cache_dir, "profile-configs-imported")
    code = os.environ.get("THUNDERSTORE_PROFILE_CODE", "").strip()
    if os.path.exists(marker) and open(marker).read().strip() == code:
        return
    config_dir = os.path.join(server_dir, "BepInEx", "config")
    count = 0
    with zipfile.ZipFile(io.BytesIO(profile_zip)) as z:
        for info in z.infolist():
            name = info.filename.replace("\\", "/")
            if name.endswith("/") or not name.lower().endswith(CONFIG_EXTENSIONS):
                continue
            for prefix in ("BepInEx/config/", "config/"):
                if name.startswith(prefix):
                    rel = name[len(prefix):]
                    target = os.path.normpath(os.path.join(config_dir, rel))
                    if not target.startswith(os.path.abspath(config_dir) + os.sep) or os.path.exists(target):
                        break
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    with z.open(info) as src, open(target, "wb") as out:
                        shutil.copyfileobj(src, out)
                    count += 1
                    break
    os.makedirs(cache_dir, exist_ok=True)
    with open(marker, "w") as f:
        f.write(code)
    log(f"Imported {count} config files from the profile (existing files were kept)")


# ----------------------------------------------------------------------- commands

def plan(installer, resolved):
    installed = installer.installed()
    to_install = {k: p for k, p in resolved.items() if not installer.is_current(k, p)}
    to_remove = [k for k in installed if k not in resolved]
    return to_install, to_remove


def describe(installer, to_install, to_remove):
    for key, pkg in to_install.items():
        cur = installer.installed().get(key)
        if cur:
            log(f"  update  {pkg['id']} {cur['version']} -> {pkg['version']}")
        else:
            log(f"  install {pkg['id']} {pkg['version']}")
    for key in to_remove:
        cur = installer.installed()[key]
        log(f"  remove  {cur.get('id', key)} {cur.get('version', '')}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["sync", "check", "list"])
    parser.add_argument("--server-dir", default=os.environ.get("SERVER_DIR", "/opt/valheim"))
    parser.add_argument("--cache-dir", default=os.environ.get("MODS_CACHE_DIR", "/config/.thunderstore"))
    args = parser.parse_args()

    installer = Installer(args.server_dir, os.path.join(args.server_dir, ".thunderstore-state.json"))

    if args.command == "list":
        for key, cur in sorted(installer.installed().items()):
            print(f"{cur.get('id', key)} {cur.get('version')}")
        return 0

    excluded = {mod_key(*parse_spec(s)[:2]) for s in split_list(os.environ.get("MODS_EXCLUDE")) if parse_spec(s)}
    try:
        specs, profile_zip = wanted_specs(args.cache_dir)
    except Exception as e:
        log(f"ERROR: {e}")
        return 1
    resolved, errors = resolve(Api(), specs, excluded)
    for err in errors:
        log(f"ERROR: {err}")
    if errors and args.command == "check":
        return 1

    to_install, to_remove = plan(installer, resolved)
    # If anything failed to resolve, the dependency tree is incomplete: never remove
    # mods based on it (Thunderstore being down must not wipe the server's mods).
    if errors and to_remove:
        log("Not removing any mods this time because some packages could not be resolved")
        to_remove = []

    if args.command == "check":
        if to_install or to_remove:
            log("Mod updates available:")
            describe(installer, to_install, to_remove)
            return UPDATE_AVAILABLE
        return 0

    if not to_install and not to_remove:
        log(f"All {len(resolved)} packages are up to date" if resolved else "No mods configured")
    else:
        describe(installer, to_install, to_remove)
    status = 1 if errors else 0
    order = sorted(to_install, key=lambda k: k != BEPINEX_PACK.lower())  # BepInEx first
    for key in order:
        pkg = to_install[key]
        try:
            installer.install(key, pkg)
        except Exception as e:
            log(f"ERROR installing {pkg['id']} {pkg['version']}: {e}")
            status = 1
    for key in to_remove:
        installer.remove(key)
    if profile_zip and truthy(os.environ.get("PROFILE_IMPORT_CONFIGS"), default=True):
        import_profile_configs(profile_zip, args.server_dir, args.cache_dir)
    return status


if __name__ == "__main__":
    sys.exit(main())
