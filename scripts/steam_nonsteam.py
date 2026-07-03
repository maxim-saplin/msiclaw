#!/usr/bin/env python3
"""List and uninstall non-Steam Steam games + orphan compatdata on Linux."""

import argparse
import glob
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

# --- binary KeyValues (shortcuts.vdf) ---

TYPE_END = 0x08
TYPE_STRING = 0x01
TYPE_INT = 0x02
TYPE_NONE = 0x00


class VDFParseError(Exception):
    pass


def read_cstring(data, offset):
    end = data.index(b"\x00", offset)
    return data[offset:end].decode("utf-8", "replace"), end + 1


def parse_vdf_map(data, offset):
    obj = {}
    while offset < len(data):
        t = data[offset]
        if t == TYPE_END:
            return obj, offset + 1
        if t == TYPE_NONE:
            offset += 1
            key, offset = read_cstring(data, offset)
            nested, offset = parse_vdf_map(data, offset)
            obj[key] = nested
        elif t == TYPE_STRING:
            offset += 1
            key, offset = read_cstring(data, offset)
            val, offset = read_cstring(data, offset)
            obj[key] = val
        elif t == TYPE_INT:
            offset += 1
            key, offset = read_cstring(data, offset)
            if offset + 4 > len(data):
                raise VDFParseError("truncated int")
            obj[key] = struct.unpack("<I", data[offset : offset + 4])[0]
            offset += 4
        else:
            raise VDFParseError(f"unsupported type {t:#x} at offset {offset}")
    raise VDFParseError("unterminated map")


def parse_vdf(data, offset=0):
    if offset >= len(data) or data[offset] != TYPE_NONE:
        raise VDFParseError(f"expected map at offset {offset}")
    offset += 1
    name, offset = read_cstring(data, offset)
    obj, offset = parse_vdf_map(data, offset)
    return name, obj, offset


def pack_steam_int(value):
    v = int(value)
    if v >= 2**31:
        v -= 2**32
    return struct.pack("<i", v)


def emit_map(obj):
    parts = []
    for key, value in obj.items():
        if isinstance(value, dict):
            parts.append(bytes([TYPE_NONE]))
            parts.append(emit_cstring(key))
            parts.extend(emit_map(value))
            parts.append(bytes([TYPE_END]))
        elif isinstance(value, int):
            parts.append(bytes([TYPE_INT]))
            parts.append(emit_cstring(key))
            parts.append(pack_steam_int(value))
        else:
            parts.append(bytes([TYPE_STRING]))
            parts.append(emit_cstring(key))
            parts.append(emit_cstring(str(value)))
    return parts


def emit_cstring(s):
    return s.encode("utf-8") + b"\x00"


def write_shortcut_map(key, entry):
    """Emit one numbered shortcut child map (00 key 00 ... 08)."""
    out = bytearray()
    out.append(TYPE_NONE)
    out.extend(emit_cstring(key))
    for chunk in emit_map(entry):
        out.extend(chunk)
    out.append(TYPE_END)
    return bytes(out)


def write_vdf_shortcuts(shortcuts_map):
    out = bytearray()
    out.append(TYPE_NONE)
    out.extend(emit_cstring("shortcuts"))
    for key, entry in iter_shortcuts(shortcuts_map):
        out.extend(write_shortcut_map(key, entry))
    out.append(TYPE_END)
    out.append(TYPE_END)
    return bytes(out)


def load_shortcuts(path_or_data):
    if isinstance(path_or_data, (bytes, bytearray)):
        data = bytes(path_or_data)
    else:
        data = Path(path_or_data).read_bytes()
    root_name, root_obj, offset = parse_vdf(data)
    if root_name != "shortcuts":
        raise VDFParseError(f"expected shortcuts root, got {root_name!r}")
    while offset < len(data) and data[offset] == TYPE_END:
        offset += 1
    if offset != len(data):
        raise VDFParseError(f"trailing bytes: {len(data) - offset}")
    return root_obj


def save_shortcuts(path, shortcuts_map):
    data = write_vdf_shortcuts(shortcuts_map)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(data)
    tmp.replace(path)


def iter_shortcuts(shortcuts_map):
    entries = []
    for key in sorted(shortcuts_map.keys(), key=lambda k: int(k) if k.isdigit() else k):
        entry = shortcuts_map[key]
        if not isinstance(entry, dict):
            continue
        entries.append((key, entry))
    return entries


def reindex_shortcuts(shortcuts_map):
    ordered = [entry for _, entry in iter_shortcuts(shortcuts_map)]
    return {str(i): entry for i, entry in enumerate(ordered)}


def remove_shortcut_by_appid(shortcuts_map, appid):
    new_map = {}
    removed = None
    for key, entry in iter_shortcuts(shortcuts_map):
        if entry.get("appid") == appid:
            removed = entry
            continue
        new_map[key] = entry
    if removed is None:
        return shortcuts_map, None
    return reindex_shortcuts(new_map), removed


# --- Steam paths ---

STEAM_PROCS = ("steam", "bazzite-steam", "steamos-manager", "steamwebhelper")


def steam_home() -> Path:
    """Effective user home — use HOME env (set by Decky plugin), not root's home."""
    return Path(os.environ.get("HOME") or os.path.expanduser("~"))


def find_steam_root():
    home = steam_home()
    candidates = [
        home / ".local/share/Steam",
        home / ".steam/root",
        home / ".steam/steam",
    ]
    override = os.environ.get("STEAM_NONSTEAM_HOME")
    if override:
        candidates.insert(0, Path(override))
    for p in candidates:
        if (p / "steamapps").is_dir():
            return p.resolve()
    return home / ".local/share/Steam"


def find_userdata_id(steam_root):
    userdata = steam_root / "userdata"
    if not userdata.is_dir():
        return None
    ids = [d.name for d in userdata.iterdir() if d.is_dir() and d.name.isdigit()]
    if len(ids) == 1:
        return ids[0]
    # pick largest config dir
    best = None
    best_score = -1
    for uid in ids:
        cfg = userdata / uid / "config"
        score = len(list(cfg.glob("*"))) if cfg.is_dir() else 0
        if score > best_score:
            best_score = score
            best = uid
    return best


def steam_running():
    try:
        out = subprocess.check_output(["pgrep", "-af", "."], text=True, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False
    for line in out.splitlines():
        low = line.lower()
        for proc in STEAM_PROCS:
            if proc in low and "pgrep" not in low:
                return True
    return False


def du_bytes(path):
    if not path.exists():
        return 0
    try:
        out = subprocess.check_output(["du", "-sb", str(path)], text=True, stderr=subprocess.DEVNULL)
        return int(out.split()[0])
    except (subprocess.CalledProcessError, ValueError, FileNotFoundError):
        total = 0
        if path.is_file():
            try:
                return path.stat().st_size
            except OSError:
                return 0
        for root, _dirs, files in os.walk(path):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
        return total


def json_mode():
    return os.environ.get("STEAM_NONSTEAM_JSON", "0") == "1"


def emit_json(obj):
    print(json.dumps(obj, indent=2))


def disk_dict(avail, total):
    return {
        "avail_bytes": avail,
        "total_bytes": total,
        "avail_gb": round(avail / (1024 ** 3), 2),
        "total_gb": round(total / (1024 ** 3), 2),
    }


def item_to_json(item, index):
    base = {
        "index": index,
        "item_type": item["item_type"],
        "appid": item["appid"],
        "name": item["name"],
        "total_bytes": item.get("total_bytes", 0),
        "total_gb": round(item.get("total_bytes", 0) / (1024 ** 3), 1),
    }
    if item["item_type"] == "game":
        base.update({
            "exe": item.get("exe", ""),
            "install_label": item.get("install_label", ""),
            "install_bytes": item.get("install_bytes", 0),
            "compat_bytes": item.get("compat_bytes", 0),
            "shader_bytes": item.get("shader_bytes", 0),
            "grid_bytes": item.get("grid_bytes", 0),
            "uninstallable": True,
        })
    else:
        base.update({
            "kind": item.get("kind", ""),
            "compat_bytes": item.get("compat_bytes", 0),
            "shader_bytes": item.get("shader_bytes", 0),
            "uninstallable": True,
        })
    return base


def build_list_json(items, games=None, steam_root=None, userdata_id=None):
    avail, total = disk_usage_home()
    games_n = sum(1 for i in items if i["item_type"] == "game")
    orphans = sum(1 for i in items if i["item_type"] == "orphan")
    ghosts = []
    if games is not None and steam_root is not None and userdata_id is not None:
        ghosts = find_ghost_tiles(games, steam_root, userdata_id)
    return {
        "ok": True,
        "disk": disk_dict(avail, total),
        "items": [item_to_json(item, idx) for idx, item in enumerate(items, 1)],
        "counts": {"games": games_n, "orphans": orphans},
        "ghosts": ghosts,
    }


def cmd_list_json(items, games=None, steam_root=None, userdata_id=None):
    emit_json(build_list_json(items, games, steam_root, userdata_id))


def fmt_size(n):
    if n <= 0:
        return "—"
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    size = float(n)
    for unit in units:
        if size < 1024 or unit == "TiB":
            if unit == "B":
                return f"{int(size)} B"
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TiB"


def disk_usage(path=None):
    """Return (avail_bytes, total_bytes) for the filesystem containing path."""
    target = Path(path) if path else steam_home()
    while not target.exists() and target != target.parent:
        target = target.parent
    st = os.statvfs(target)
    total = st.f_frsize * st.f_blocks
    avail = st.f_frsize * st.f_bavail
    return avail, total


def disk_usage_home():
    """Disk stats at user home — consistent for list and post-uninstall display."""
    return disk_usage(steam_home())


def poll_disk_freed(avail_before, attempts=15, delay_s=0.5):
    """Re-read home filesystem; btrfs may delay statvfs updates after large deletes."""
    try:
        subprocess.run(["sync"], timeout=60, check=False)
    except (OSError, subprocess.SubprocessError):
        pass
    best_avail, best_total = disk_usage_home()
    best_delta = best_avail - avail_before
    for _ in range(attempts):
        if best_delta > 0:
            break
        time.sleep(delay_s)
        best_avail, best_total = disk_usage_home()
        best_delta = best_avail - avail_before
    return best_avail, best_total, best_delta


def disk_after_uninstall(avail_before, total, freed, polled_avail, polled_total, polled_delta):
    """Prefer measured statvfs; fall back to deleted-bytes estimate when btrfs lags."""
    measured = polled_delta
    avail_after = polled_avail
    total_after = polled_total
    if measured <= 0 and freed > 0:
        measured = freed
        avail_after = avail_before + freed
    return avail_after, total_after, measured


def fmt_gb(n):
    if n < 0:
        return "—"
    return f"{n / (1024 ** 3):.1f} GB"


def fmt_disk_avail_total(avail, total):
    return f"{fmt_gb(avail)} available / {fmt_gb(total)} total"


def print_disk_space(path=None, prefix="Disk"):
    avail, total = disk_usage(path)
    print(f"{prefix}: {fmt_disk_avail_total(avail, total)}")
    return avail, total


def strip_quotes(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    return s


def normalize_path(p):
    if not p:
        return None
    p = strip_quotes(p)
    p = os.path.expanduser(p)
    try:
        return Path(p).resolve()
    except (OSError, RuntimeError):
        return Path(p)


def is_system_path(path):
    if path is None:
        return True
    try:
        path.resolve().relative_to(steam_home().resolve())
        return False
    except ValueError:
        pass
    try:
        resolved = path.resolve()
        for root in (
            Path("/usr"),
            Path("/opt"),
            Path("/sbin"),
            Path("/lib"),
            Path("/lib64"),
            Path("/var/lib"),
        ):
            try:
                resolved.relative_to(root)
                return True
            except ValueError:
                continue
    except OSError:
        return True
    return False


def is_gog_in_prefix(exe_path, compat_dir):
    if exe_path is None:
        return False
    try:
        exe_path.resolve().relative_to(compat_dir.resolve())
        return True
    except ValueError:
        return False


def install_dir_for(entry, steam_root, appid):
    compat = steam_root / "steamapps/compatdata" / str(appid)
    startdir = normalize_path(entry.get("StartDir") or entry.get("startdir") or "")
    exe = normalize_path(strip_quotes(entry.get("Exe") or entry.get("exe") or ""))

    if exe and is_gog_in_prefix(exe, compat):
        # GOG installed inside proton prefix — install is under drive_c
        drive_c = compat / "pfx/drive_c"
        if startdir and startdir.exists():
            return startdir
        return exe.parent

    if startdir and startdir.exists():
        return startdir
    if exe:
        return exe.parent
    return startdir


def install_deletable(install_path, home, appid, steam_root):
    if install_path is None or not install_path.exists():
        return False, "missing"
    if is_system_path(install_path):
        return False, "system"
    compat = steam_root / "steamapps/compatdata" / str(appid)
    games_root = Path(home) / "Games"
    try:
        install_path.resolve().relative_to(games_root.resolve())
        return True, "games"
    except ValueError:
        pass
    drive_c = compat / "pfx/drive_c"
    if drive_c.exists():
        try:
            install_path.resolve().relative_to(drive_c.resolve())
            return True, "prefix"
        except ValueError:
            pass
    return False, "outside_allowlist"


def parse_shortcut_entry(key, entry, steam_root, userdata_id):
    appid = int(entry.get("appid", 0)) & 0xFFFFFFFF
    name = entry.get("AppName") or entry.get("appname") or f"shortcut-{key}"
    exe_raw = entry.get("Exe") or entry.get("exe") or ""
    compat_dir = steam_root / "steamapps/compatdata" / str(appid)
    shader_dir = steam_root / "steamapps/shadercache" / str(appid)
    meta_paths = steam_metadata_paths(steam_root, userdata_id, appid)
    grid_glob = str(steam_root / f"userdata/{userdata_id}/config/grid/{appid}*")
    libcache = steam_root / f"userdata/{userdata_id}/config/librarycache/{appid}.json"

    install_path = install_dir_for(entry, steam_root, appid)
    gog_in_prefix = is_gog_in_prefix(normalize_path(strip_quotes(exe_raw)), compat_dir)
    exe_path = normalize_path(strip_quotes(exe_raw))
    system_launcher = is_system_path(install_path) or is_system_path(exe_path)

    if gog_in_prefix or system_launcher:
        install_bytes = 0
    else:
        install_bytes = du_bytes(install_path)
    compat_bytes = du_bytes(compat_dir)
    shader_bytes = du_bytes(shader_dir)
    grid_bytes = sum(du_bytes(p) for p in meta_paths if "/grid/" in str(p))
    libcache_bytes = sum(du_bytes(p) for p in meta_paths if "/librarycache/" in str(p))
    meta_bytes = sum(du_bytes(p) for p in meta_paths if "/shaderhitcache/" in str(p))

    if gog_in_prefix:
        # compat includes game files
        total = compat_bytes + shader_bytes + grid_bytes + libcache_bytes + meta_bytes
        install_label = "(in prefix)"
    elif system_launcher:
        total = compat_bytes + shader_bytes + grid_bytes + libcache_bytes + meta_bytes
        install_label = "(system)"
    else:
        total = install_bytes + compat_bytes + shader_bytes + grid_bytes + libcache_bytes + meta_bytes
        install_label = fmt_size(install_bytes)

    deletable, reason = install_deletable(install_path, steam_home(), appid, steam_root)

    return {
        "index_key": key,
        "appid": appid,
        "name": name,
        "exe": strip_quotes(exe_raw),
        "install_path": install_path,
        "install_label": install_label,
        "install_bytes": install_bytes,
        "compat_dir": compat_dir,
        "compat_bytes": compat_bytes,
        "shader_dir": shader_dir,
        "shader_bytes": shader_bytes,
        "grid_glob": grid_glob,
        "grid_bytes": grid_bytes,
        "libcache": libcache,
        "libcache_bytes": libcache_bytes,
        "meta_paths": meta_paths,
        "meta_bytes": meta_bytes,
        "total_bytes": total,
        "gog_in_prefix": gog_in_prefix,
        "install_deletable": deletable,
        "install_skip_reason": reason,
        "entry": entry,
        "item_type": "game",
    }


def load_games(steam_root, userdata_id):
    shortcuts_path = steam_root / f"userdata/{userdata_id}/config/shortcuts.vdf"
    if not shortcuts_path.is_file():
        raise SystemExit(f"error: shortcuts.vdf not found: {shortcuts_path}")
    shortcuts_map = load_shortcuts(shortcuts_path.read_bytes())
    games = []
    for key, entry in iter_shortcuts(shortcuts_map):
        g = parse_shortcut_entry(key, entry, steam_root, userdata_id)
        if g:
            games.append(g)
    return games, shortcuts_path, shortcuts_map


def cmd_status(steam_root, userdata_id):
    shortcuts_path = steam_root / f"userdata/{userdata_id}/config/shortcuts.vdf"
    print(f"Steam root:     {steam_root}")
    print(f"Userdata ID:    {userdata_id}")
    print(f"shortcuts.vdf:  {shortcuts_path}")
    print(f"Steam running:  {'yes' if steam_running() else 'no'}")
    if shortcuts_path.is_file():
        try:
            smap = load_shortcuts(shortcuts_path.read_bytes())
            print(f"Shortcuts:      {len(list(iter_shortcuts(smap)))}")
        except VDFParseError as e:
            print(f"Shortcuts:      parse error: {e}")
    else:
        print("Shortcuts:      (missing)")
    print_disk_space()


def cmd_list(games, steam_root, userdata_id, items):
    if json_mode():
        cmd_list_json(items, games, steam_root, userdata_id)
        return
    print_uninstall_list(items)


def steam_app_ids(steam_root):
    ids = set()
    steamapps = steam_root / "steamapps"
    for acf in steamapps.glob("appmanifest_*.acf"):
        m = re.search(r"appmanifest_(\d+)", acf.name)
        if m:
            ids.add(int(m.group(1)))
    return ids


def find_orphans(games, steam_root):
    shortcut_ids = {g["appid"] for g in games}
    steam_ids = steam_app_ids(steam_root)
    compat_root = steam_root / "steamapps/compatdata"
    orphans = []
    if not compat_root.is_dir():
        return orphans
    for d in sorted(compat_root.iterdir(), key=lambda p: p.name):
        if not d.is_dir() or not d.name.isdigit():
            continue
        aid = int(d.name)
        if aid in shortcut_ids:
            continue
        kind = "steam app" if aid in steam_ids else "no shortcut"
        compat_dir = compat_root / str(aid)
        shader_dir = steam_root / "steamapps/shadercache" / str(aid)
        compat_bytes = du_bytes(compat_dir)
        shader_bytes = du_bytes(shader_dir)
        orphans.append({
            "item_type": "orphan",
            "appid": aid,
            "name": f"orphan {aid}",
            "kind": kind,
            "compat_dir": compat_dir,
            "compat_bytes": compat_bytes,
            "shader_dir": shader_dir,
            "shader_bytes": shader_bytes,
            "total_bytes": compat_bytes + shader_bytes,
        })
    return orphans


def build_uninstall_items(games, steam_root):
    items = []
    for g in games:
        item = dict(g)
        item["item_type"] = "game"
        items.append(item)
    items.extend(find_orphans(games, steam_root))
    return items


def print_uninstall_list(items):
    if not items:
        print("No non-Steam shortcuts or orphans found.")
        print_disk_space()
        return
    print_disk_space()
    print()
    print(f"{'#':>3}  {'Name':<28} {'AppID':<12} {'Install':>10} {'Compat':>10} {'Shader':>8} {'Grid':>8} {'Total':>10}")
    print("-" * 100)
    game_count = 0
    orphan_count = 0
    for i, item in enumerate(items, 1):
        if item["item_type"] == "game":
            game_count += 1
            print(
                f"{i:>3}  {item['name'][:28]:<28} {item['appid']:<12} "
                f"{item['install_label']:>10} {fmt_size(item['compat_bytes']):>10} "
                f"{fmt_size(item['shader_bytes']):>8} {fmt_size(item['grid_bytes']):>8} "
                f"{fmt_size(item['total_bytes']):>10}"
            )
            exe_short = item["exe"]
            if len(exe_short) > 90:
                exe_short = "..." + exe_short[-87:]
            print(f"      exe: {exe_short}")
        else:
            orphan_count += 1
            tag = " [steam app!]" if item["kind"] == "steam app" else ""
            print(
                f"{i:>3}  {'[orphan]':<28} {item['appid']:<12} "
                f"{'—':>10} {fmt_size(item['compat_bytes']):>10} "
                f"{fmt_size(item['shader_bytes']):>8} {'—':>8} "
                f"{fmt_gb(item['total_bytes']):>10}{tag}"
            )
            print(f"      {item['kind']} — compatdata only")
    print()
    parts = []
    if game_count:
        parts.append(f"{game_count} game(s)")
    if orphan_count:
        parts.append(f"{orphan_count} orphan(s)")
    print(f"Total: {', '.join(parts) if parts else '0 item(s)'}")
    if orphan_count:
        print("Orphans: uninstall removes compatdata + shadercache only (no shortcut / no ~/Games/).")


def cmd_orphans(games, steam_root):
    orphans = find_orphans(games, steam_root)
    if not orphans:
        print("No orphan compatdata folders.")
        print_disk_space()
        return
    print_disk_space()
    print()
    print(f"{'AppID':<12} {'Size':>10}  Note")
    print("-" * 40)
    for item in orphans:
        print(f"{item['appid']:<12} {fmt_gb(item['total_bytes']):>10}  {item['kind']}")
    print()
    print("Orphans appear in: steam-nonsteam-games list")
    print("Remove with:       steam-nonsteam-games uninstall <# or appid>")


def match_item(items, target):
    if not target:
        return None
    if target.isdigit():
        n = int(target)
        if 1 <= n <= len(items):
            return items[n - 1]
        for item in items:
            if item["appid"] == n:
                return item
    low = target.lower()
    matches = [
        item for item in items
        if low in item.get("name", "").lower()
        or low in str(item["appid"])
        or (item["item_type"] == "orphan" and low in "orphan")
    ]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        print("Multiple matches:")
        for item in matches:
            label = item["name"] if item["item_type"] == "game" else f"orphan {item['appid']}"
            print(f"  {label} ({item['appid']})")
        raise SystemExit(1)
    return None


def pick_interactive(items):
    print_uninstall_list(items)
    raw = prompt_line("Uninstall which number? (empty to cancel): ")
    if not raw:
        raise SystemExit("cancelled")
    item = match_item(items, raw)
    if item is None:
        raise SystemExit(f"error: no match for {raw!r}")
    return item


def dispatch_uninstall(item, steam_root, shortcuts_path, shortcuts_map, force, skip_confirm, userdata_id=None):
    if item["item_type"] == "orphan":
        return perform_orphan_uninstall(steam_root, item["appid"], force, skip_confirm, userdata_id=userdata_id)
    return perform_game_uninstall(
        steam_root, userdata_id, shortcuts_path, shortcuts_map, item, force, skip_confirm
    )


def steam_metadata_paths(steam_root, userdata_id, appid):
    """Grid art, librarycache, shaderhitcache — can leave ghost library tiles if left behind."""
    cfg = steam_root / f"userdata/{userdata_id}/config"
    paths = []
    for pattern in (
        str(cfg / "grid" / f"{appid}*"),
        str(cfg / "librarycache" / f"{appid}*"),
    ):
        paths.extend(Path(p) for p in glob.glob(pattern))
    shader_hit = cfg / "shaderhitcache"
    if shader_hit.is_dir():
        for p in shader_hit.rglob(f"*{appid}*"):
            paths.append(p)
    # stable order, dedupe
    seen = set()
    unique = []
    for p in paths:
        key = str(p.resolve())
        if key not in seen:
            seen.add(key)
            unique.append(p)
    return unique


def remove_metadata_paths(paths):
    removed = []
    freed = 0
    for path in paths:
        if not path.exists():
            continue
        size = du_bytes(path)
        rm_path(path)
        removed.append({"kind": "metadata", "path": str(path), "bytes": size})
        freed += size
    return removed, freed


def deletion_plan(game):
    paths = []
    if game["install_deletable"] and game["install_path"] and game["install_path"].exists():
        if not game["gog_in_prefix"]:
            paths.append(("install", game["install_path"], game["install_bytes"]))
    if game["compat_dir"].exists():
        paths.append(("compatdata", game["compat_dir"], game["compat_bytes"]))
    if game["shader_dir"].exists():
        paths.append(("shadercache", game["shader_dir"], game["shader_bytes"]))
    for meta in game.get("meta_paths", []):
        if meta.exists():
            paths.append(("metadata", meta, du_bytes(meta)))
    paths.append(("shortcuts.vdf", None, 0))
    return paths


def print_plan(game, paths, avail_before=None, total_before=None):
    print()
    print(f"Uninstall plan: {game['name']} (appid {game['appid']})")
    if avail_before is not None and total_before is not None:
        print(f"Disk before:    {fmt_disk_avail_total(avail_before, total_before)}")
    print("-" * 60)
    total = 0
    for kind, path, size in paths:
        if kind == "shortcuts.vdf":
            print("  shortcuts.vdf     remove shortcut entry (backup first)")
            continue
        print(f"  {kind:<14} {path}  ({fmt_size(size)})")
        total += size
    print("-" * 60)
    print(f"  Disk freed (approx): {fmt_gb(total)}")
    if not game["install_deletable"] and game["install_skip_reason"] == "system":
        print("  Note: system/launcher path will NOT be deleted.")
    elif not game["install_deletable"]:
        print(f"  Note: install dir skipped ({game['install_skip_reason']}).")
    print()


def prompt_line(message):
    """Read a line for confirmation; use /dev/tty when stdin is the embedded script."""
    try:
        with open("/dev/tty") as tty:
            sys.stdout.write(message)
            sys.stdout.flush()
            return tty.readline().strip()
    except OSError:
        try:
            return input(message).strip()
        except EOFError:
            print()
            raise SystemExit("cancelled (no input)") from None


def confirm_uninstall(game, skip_name=False, disk_path=None):
    avail_before, total = disk_usage(disk_path)
    print_plan(game, deletion_plan(game), avail_before, total)
    if skip_name:
        return avail_before, total
    ans = prompt_line(f"Type the game name to confirm ({game['name']}): ")
    if ans != game["name"]:
        raise SystemExit("confirmation failed — cancelled")
    return avail_before, total


def backup_shortcuts(shortcuts_path):
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = shortcuts_path.with_name(f"shortcuts.vdf.bak.{ts}")
    shutil.copy2(shortcuts_path, backup)
    if not json_mode():
        print(f"Backed up shortcuts.vdf -> {backup.name}")
    return backup


def rm_path(path):
    if path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink()


def verify_game_uninstall(steam_root, userdata_id, game, paths_before, avail_before, avail_after, freed):
    still_listed = False
    if userdata_id:
        try:
            games, _, _ = load_games(steam_root, userdata_id)
            still_listed = any(g["appid"] == game["appid"] for g in games)
        except SystemExit:
            still_listed = True

    paths_remaining = [str(p) for p in paths_before if p.exists()]
    if userdata_id:
        paths_remaining.extend(
            str(p) for p in steam_metadata_paths(steam_root, userdata_id, game["appid"]) if p.exists()
        )
    measured_freed_bytes = avail_after - avail_before
    verify = {
        "still_listed": still_listed,
        "paths_remaining": paths_remaining,
        "measured_freed_bytes": measured_freed_bytes,
    }

    ok = True
    errors = []
    if still_listed:
        ok = False
        errors.append("game still listed in shortcuts")
    if paths_remaining:
        ok = False
        errors.append(f"{len(paths_remaining)} path(s) still exist")
    if paths_before and freed == 0:
        ok = False
        errors.append("nothing deleted but paths were expected")

    return verify, ok, "; ".join(errors) if errors else None


def finalize_uninstall_result(result, verify, ok, error_msg):
    result["verify"] = verify
    result["ok"] = ok
    if error_msg:
        result["error"] = error_msg
    return result


def perform_game_uninstall(
    steam_root, userdata_id, shortcuts_path, shortcuts_map, game, force, skip_confirm=False, emit_result=True
):
    if steam_running() and not force:
        raise SystemExit(
            "error: Steam appears to be running. Stop Steam first, or pass --force.\n"
            "  On Bazzite: exit Gaming Mode / stop bazzite-steam before uninstall."
        )
    if force and steam_running() and not json_mode():
        print("warning: --force set while Steam is running; shortcuts.vdf may be overwritten on Steam exit.")

    disk_path = game.get("install_path") or steam_home()
    if json_mode() and skip_confirm:
        avail_before, total = disk_usage_home()
    else:
        avail_before, total = confirm_uninstall(game, skip_name=skip_confirm, disk_path=disk_path)
    backup_shortcuts(shortcuts_path)

    freed = 0
    removed = []
    plan = deletion_plan(game)
    paths_before = [path for kind, path, size in plan if path is not None and path.exists()]

    for kind, path, size in plan:
        if path is None:
            continue
        if path.exists():
            if not json_mode():
                print(f"Removing {kind}: {path}")
            rm_path(path)
            freed += size
            removed.append({"kind": kind, "path": str(path), "bytes": size})
        elif not json_mode():
            print(f"Skipping {kind} (not found): {path}")

    new_map, removed_entry = remove_shortcut_by_appid(shortcuts_map, game["appid"])
    if removed_entry is None:
        if not json_mode():
            print("warning: shortcut entry not found in shortcuts.vdf")
    else:
        save_shortcuts(shortcuts_path, new_map)
        removed.append({"kind": "shortcuts.vdf", "path": str(shortcuts_path), "bytes": 0})
        if not json_mode():
            print(f"Removed shortcut entry for appid {game['appid']}")

    # Re-scan metadata — Steam may recreate librarycache while running; shaderhitcache was missed before.
    extra_meta, extra_freed = remove_metadata_paths(
        steam_metadata_paths(steam_root, userdata_id, game["appid"])
    )
    removed.extend(extra_meta)
    freed += extra_freed
    cleanup_ghost_appid(steam_root, userdata_id, shortcuts_path, shortcuts_map, game["appid"])

    polled_avail, polled_total, polled_delta = poll_disk_freed(avail_before)
    avail_after, total_after, measured_freed = disk_after_uninstall(
        avail_before, total, freed, polled_avail, polled_total, polled_delta
    )
    verify, ok, error_msg = verify_game_uninstall(
        steam_root, userdata_id, game, paths_before, avail_before, avail_after, freed
    )
    verify["measured_freed_bytes"] = measured_freed
    steam_restart = steam_running()
    result = finalize_uninstall_result({
        "item_type": "game",
        "appid": game["appid"],
        "name": game["name"],
        "freed_bytes": freed,
        "freed_gb": round(freed / (1024 ** 3), 2),
        "disk_before": disk_dict(avail_before, total),
        "disk_after": disk_dict(avail_after, total_after),
        "removed": removed,
        "steam_restart_recommended": steam_restart,
    }, verify, ok, error_msg)
    if json_mode() and emit_result:
        emit_json(result)
    elif not json_mode():
        print()
        print(f"Disk before:    {fmt_disk_avail_total(avail_before, total)}")
        print(f"Disk after:     {fmt_disk_avail_total(avail_after, total_after)}")
        print(f"Freed:          {fmt_gb(freed)} (deleted); {fmt_gb(avail_after - avail_before)} (measured)")
        if not ok:
            print(f"warning: verification failed: {error_msg}")
        print("Restart Steam to refresh the library.")
    return result


def cmd_uninstall(steam_root, userdata_id, shortcuts_path, shortcuts_map, game, force, skip_confirm=False):
    return perform_game_uninstall(
        steam_root, userdata_id, shortcuts_path, shortcuts_map, game, force, skip_confirm
    )


def verify_orphan_uninstall(steam_root, userdata_id, appid, paths_before, avail_before, avail_after, freed):
    still_listed = False
    if userdata_id:
        try:
            games, _, _ = load_games(steam_root, userdata_id)
            items_after = build_uninstall_items(games, steam_root)
            still_listed = any(i["appid"] == appid for i in items_after)
        except SystemExit:
            still_listed = True

    paths_remaining = [str(p) for p in paths_before if p.exists()]
    measured_freed_bytes = avail_after - avail_before
    verify = {
        "still_listed": still_listed,
        "paths_remaining": paths_remaining,
        "measured_freed_bytes": measured_freed_bytes,
    }

    ok = True
    errors = []
    if still_listed:
        ok = False
        errors.append("orphan still listed")
    if paths_remaining:
        ok = False
        errors.append(f"{len(paths_remaining)} path(s) still exist")
    if paths_before and freed == 0:
        ok = False
        errors.append("nothing deleted but paths were expected")

    return verify, ok, "; ".join(errors) if errors else None


def perform_orphan_uninstall(
    steam_root, appid, force, skip_confirm=False, emit_result=True, userdata_id=None
):
    if steam_running() and not force:
        raise SystemExit("error: Steam appears to be running. Stop Steam first, or pass --force.")
    compat = steam_root / "steamapps/compatdata" / str(appid)
    shader = steam_root / "steamapps/shadercache" / str(appid)
    if not compat.exists() and not shader.exists():
        raise SystemExit(f"error: no compatdata/shadercache for appid {appid}")
    compat_bytes = du_bytes(compat) if compat.exists() else 0
    shader_bytes = du_bytes(shader) if shader.exists() else 0
    size = compat_bytes + shader_bytes
    avail_before, total = disk_usage_home()
    if not json_mode():
        print(f"Orphan cleanup: appid {appid} ({fmt_gb(size)})")
        print(f"Disk before:    {fmt_disk_avail_total(avail_before, total)}")
        print(f"  {compat}")
        print(f"  {shader}")
    if not skip_confirm:
        ans = prompt_line("Type 'yes' to confirm: ")
        if ans != "yes":
            raise SystemExit("cancelled")
    removed = []
    paths_before = [p for p in (compat, shader) if p.exists()]
    freed = 0
    if compat.exists():
        shutil.rmtree(compat)
        removed.append({"kind": "compatdata", "path": str(compat), "bytes": compat_bytes})
        freed += compat_bytes
        if not json_mode():
            print(f"Removed {compat}")
    if shader.exists():
        shutil.rmtree(shader)
        removed.append({"kind": "shadercache", "path": str(shader), "bytes": shader_bytes})
        freed += shader_bytes
        if not json_mode():
            print(f"Removed {shader}")
    polled_avail, polled_total, polled_delta = poll_disk_freed(avail_before)
    avail_after, total_after, measured_freed = disk_after_uninstall(
        avail_before, total, freed, polled_avail, polled_total, polled_delta
    )
    verify, ok, error_msg = verify_orphan_uninstall(
        steam_root, userdata_id, appid, paths_before, avail_before, avail_after, freed
    )
    verify["measured_freed_bytes"] = measured_freed
    result = finalize_uninstall_result({
        "item_type": "orphan",
        "appid": appid,
        "name": f"orphan {appid}",
        "freed_bytes": freed,
        "freed_gb": round(freed / (1024 ** 3), 2),
        "disk_before": disk_dict(avail_before, total),
        "disk_after": disk_dict(avail_after, total_after),
        "removed": removed,
        "steam_restart_recommended": steam_running(),
    }, verify, ok, error_msg)
    if json_mode() and emit_result:
        emit_json(result)
    elif not json_mode():
        print()
        print(f"Disk before:    {fmt_disk_avail_total(avail_before, total)}")
        print(f"Disk after:     {fmt_disk_avail_total(avail_after, total_after)}")
        print(f"Freed:          {fmt_gb(freed)} (deleted); {fmt_gb(avail_after - avail_before)} (measured)")
        if not ok:
            print(f"warning: verification failed: {error_msg}")
    return result


def cmd_orphan_uninstall(steam_root, appid, force, skip_confirm=False, userdata_id=None):
    return perform_orphan_uninstall(steam_root, appid, force, skip_confirm, userdata_id=userdata_id)


# Non-Steam shortcut appids are large unsigned 32-bit hashes; Steam store ids are much smaller.
NONSTEAM_APPID_MIN = 1_000_000_000


def find_ghost_tiles(games, steam_root, userdata_id):
    """librarycache for deleted non-Steam shortcuts — ghost tiles without artwork."""
    shortcut_ids = {g["appid"] for g in games}
    cfg = steam_root / f"userdata/{userdata_id}/config/librarycache"
    ghosts = []
    if not cfg.is_dir():
        return ghosts
    for p in sorted(cfg.glob("*.json")):
        try:
            appid = int(p.stem)
        except ValueError:
            continue
        if appid in shortcut_ids or appid < NONSTEAM_APPID_MIN:
            continue
        ghosts.append({"appid": appid, "librarycache": str(p)})
    return ghosts


def cleanup_ghost_appid(steam_root, userdata_id, shortcuts_path, shortcuts_map, appid):
    """Remove leftover Steam UI metadata (and shortcut if still present) for a ghost tile."""
    meta_removed, freed = remove_metadata_paths(steam_metadata_paths(steam_root, userdata_id, appid))
    new_map, removed_entry = remove_shortcut_by_appid(shortcuts_map, appid)
    shortcut_removed = removed_entry is not None
    if shortcut_removed:
        save_shortcuts(shortcuts_path, new_map)
    return {
        "ok": True,
        "appid": appid,
        "shortcut_removed": shortcut_removed,
        "removed": meta_removed,
        "freed_bytes": freed,
        "steam_restart_recommended": steam_running(),
    }


def cmd_cleanup_ghost(steam_root, userdata_id, shortcuts_path, shortcuts_map, appid):
    result = cleanup_ghost_appid(steam_root, userdata_id, shortcuts_path, shortcuts_map, appid)
    if json_mode():
        emit_json(result)
    else:
        print(f"Ghost cleanup appid {appid}: metadata={len(result['removed'])} shortcut_removed={result['shortcut_removed']}")
        for r in result["removed"]:
            print(f"  removed {r['path']}")
    return result


def cmd_cleanup_all_ghosts(games, steam_root, userdata_id, shortcuts_path, shortcuts_map):
    ghosts = find_ghost_tiles(games, steam_root, userdata_id)
    cleaned = []
    all_removed = []
    total_freed = 0
    smap = shortcuts_map
    for g in ghosts:
        r = cleanup_ghost_appid(steam_root, userdata_id, shortcuts_path, smap, g["appid"])
        if r.get("shortcut_removed"):
            smap = load_shortcuts(shortcuts_path.read_bytes())
        cleaned.append(r["appid"])
        all_removed.extend(r["removed"])
        total_freed += r["freed_bytes"]
    result = {
        "ok": True,
        "count": len(cleaned),
        "appids": cleaned,
        "removed": all_removed,
        "freed_bytes": total_freed,
        "steam_restart_recommended": True,
    }
    if json_mode():
        emit_json(result)
    else:
        print(f"Cleaned {len(cleaned)} ghost tile(s)")
        for aid in cleaned:
            print(f"  appid {aid}")
    return result


def cmd_validate(games, steam_root, shortcuts_path, shortcuts_map, force, safe_only=False):
    tests = []
    disk_before_avail, disk_before_total = disk_usage(steam_home())
    disk_before = disk_dict(disk_before_avail, disk_before_total)

    home = steam_home()
    userdata_id = find_userdata_id(steam_root)
    if str(home) == "/root" or not (steam_root / "userdata").is_dir():
        tests.append({
            "name": "home_env",
            "pass": False,
            "detail": f"HOME={home} steam_root={steam_root}",
        })
    else:
        tests.append({
            "name": "home_env",
            "pass": True,
            "detail": f"HOME={home}",
        })

    if userdata_id:
        tests.append({
            "name": "userdata_found",
            "pass": True,
            "detail": userdata_id,
        })
    else:
        tests.append({
            "name": "userdata_found",
            "pass": False,
            "detail": "no userdata ID",
        })

    items = []
    try:
        items = build_uninstall_items(games, steam_root)
        payload = build_list_json(items, games, steam_root, userdata_id)
        assert payload.get("ok") is True
        assert "disk" in payload and "items" in payload
        for it in payload["items"]:
            assert it["item_type"] in ("game", "orphan")
            assert "appid" in it and "total_bytes" in it
        tests.append({
            "name": "list_schema",
            "pass": True,
            "detail": f"{len(payload['items'])} items",
        })
    except Exception as exc:
        tests.append({"name": "list_schema", "pass": False, "detail": str(exc)})

    if disk_before_total > 0 and 0 <= disk_before_avail <= disk_before_total:
        tests.append({
            "name": "disk_readable",
            "pass": True,
            "detail": fmt_disk_avail_total(disk_before_avail, disk_before_total),
        })
    else:
        tests.append({
            "name": "disk_readable",
            "pass": False,
            "detail": f"invalid disk stats: {disk_before}",
        })

    candidate = next(
        (i for i in items if i["item_type"] == "orphan" and i.get("kind") == "no shortcut"),
        None,
    )
    if safe_only:
        tests.append({
            "name": "orphan_delete",
            "pass": True,
            "detail": "skipped: --safe-only",
        })
    elif candidate is None:
        tests.append({
            "name": "orphan_delete",
            "pass": True,
            "detail": "skipped: no safe orphan",
        })
    else:
        appid = candidate["appid"]
        avail_pre, _ = disk_usage(steam_home())
        try:
            perform_orphan_uninstall(
                steam_root, appid, force, skip_confirm=True, emit_result=False, userdata_id=find_userdata_id(steam_root)
            )
            items_after = build_uninstall_items(games, steam_root)
            still_there = any(i["appid"] == appid for i in items_after)
            avail_post, _ = disk_usage(steam_home())
            if not still_there and avail_post >= avail_pre:
                tests.append({
                    "name": "orphan_delete",
                    "pass": True,
                    "detail": f"removed appid {appid}",
                })
            else:
                tests.append({
                    "name": "orphan_delete",
                    "pass": False,
                    "detail": f"still_present={still_there} avail_delta={avail_post - avail_pre}",
                })
        except Exception as exc:
            tests.append({"name": "orphan_delete", "pass": False, "detail": str(exc)})

    disk_after_avail, disk_after_total = disk_usage(steam_home())
    ok = all(t["pass"] for t in tests)
    report = {
        "ok": ok,
        "tests": tests,
        "disk_before": disk_before,
        "disk_after": disk_dict(disk_after_avail, disk_after_total),
    }
    if json_mode():
        emit_json(report)
    else:
        print("Validation report:")
        for t in tests:
            status = "PASS" if t["pass"] else "FAIL"
            print(f"  [{status}] {t['name']}: {t['detail']}")
        print(f"Overall: {'ok' if ok else 'FAILED'}")
    return report


def parse_cli():
    parser = argparse.ArgumentParser(description="List/uninstall non-Steam Steam games")
    parser.add_argument("command", nargs="?", default="list",
                        choices=["list", "status", "orphans", "uninstall", "validate", "cleanup", "cleanup-all", "ghosts"])
    parser.add_argument("target", nargs="?", default=None)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--yes", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--safe-only", action="store_true")
    return parser.parse_args()


def main():
    args = parse_cli()
    if args.json:
        os.environ["STEAM_NONSTEAM_JSON"] = "1"
    if args.force:
        os.environ["STEAM_NONSTEAM_FORCE"] = "1"
    if args.yes:
        os.environ["STEAM_NONSTEAM_YES"] = "1"

    force = args.force
    skip_confirm = args.yes
    cmd = args.command
    cli_args = [args.target] if args.target else []

    steam_root = find_steam_root()
    userdata_id = find_userdata_id(steam_root)
    if not userdata_id:
        raise SystemExit("error: could not determine Steam userdata ID")

    if cmd == "status":
        cmd_status(steam_root, userdata_id)
        return

    games, shortcuts_path, shortcuts_map = load_games(steam_root, userdata_id)
    items = build_uninstall_items(games, steam_root)

    if cmd == "list":
        cmd_list(games, steam_root, userdata_id, items)
        return

    if cmd == "orphans":
        cmd_orphans(games, steam_root)
        return

    if cmd == "validate":
        if not force:
            raise SystemExit("error: validate requires --force when Steam may be running")
        cmd_validate(games, steam_root, shortcuts_path, shortcuts_map, force, safe_only=args.safe_only)
        return

    if cmd == "uninstall":
        target = cli_args[0] if cli_args else None
        if not target:
            if json_mode():
                raise SystemExit("error: uninstall requires a target in --json mode")
            item = pick_interactive(items)
            dispatch_uninstall(
                item, steam_root, shortcuts_path, shortcuts_map, force, skip_confirm, userdata_id
            )
            return
        item = match_item(items, target)
        if item is None:
            raise SystemExit(f"error: no match for {target!r}")
        dispatch_uninstall(
            item, steam_root, shortcuts_path, shortcuts_map, force, skip_confirm, userdata_id
        )
        return

    if cmd == "ghosts":
        ghosts = find_ghost_tiles(games, steam_root, userdata_id)
        if json_mode():
            emit_json({"ok": True, "ghosts": ghosts})
        else:
            if not ghosts:
                print("No ghost library tiles found.")
            for g in ghosts:
                print(f"  appid {g['appid']}  {g['librarycache']}")
            print("Cleanup: steam-nonsteam-games cleanup <appid>")
        return

    if cmd == "cleanup":
        target = cli_args[0] if cli_args else None
        if not target:
            raise SystemExit("error: cleanup requires an appid")
        appid = int(target) if target.isdigit() else None
        if appid is None:
            item = match_item(items, target)
            if item is None:
                raise SystemExit(f"error: no match for {target!r}")
            appid = item["appid"]
        cmd_cleanup_ghost(steam_root, userdata_id, shortcuts_path, shortcuts_map, appid)
        return

    if cmd == "cleanup-all":
        cmd_cleanup_all_ghosts(games, steam_root, userdata_id, shortcuts_path, shortcuts_map)
        return

    raise SystemExit(f"error: unknown command: {cmd}")


if __name__ == "__main__":
    main()
