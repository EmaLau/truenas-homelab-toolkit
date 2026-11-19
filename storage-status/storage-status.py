#!/usr/bin/env python3
"""Pool space, cloud storage space and snapshot task status -> one JSON file for dashboards.

Output path: $STORAGE_STATUS_OUT (default /var/tmp/storage_status.json).
Schema: docs/storage-status.schema.json. Values are raw numbers (bytes, Unix
timestamps, hours): formatting is left to the dashboard.
"""

import configparser
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime

SCHEMA_VERSION = 1
OUT = os.environ.get("STORAGE_STATUS_OUT", "/var/tmp/storage_status.json")
# Cloud free space thresholds (percent): below WARN -> LOW, below CRIT -> CRITICAL.
WARN_PCT, CRIT_PCT = 20, 10
# TrueNAS cloud credential type -> (rclone backend, name used in the JSON).
# Other providers are skipped: not every rclone backend reports free space.
PROVIDERS = {"ONEDRIVE": ("onedrive", "onedrive"), "GOOGLE_DRIVE": ("drive", "google_drive")}
# rclone may refresh these during "about"; like TrueNAS after a cloud sync, save them back.
REFRESHED_KEYS = ("token",)


def log(msg):
    print(f"storage-status: {msg}", file=sys.stderr)


def midclt(*args):
    return json.loads(subprocess.check_output(["midclt", "call", *args], timeout=60))


def pct(part, total):
    return round(100 * part / total) if total and part is not None else None


def save_refreshed_credentials(cred, path):
    """Store tokens that rclone refreshed, as TrueNAS does after a cloud sync."""
    ini = configparser.ConfigParser(interpolation=None)
    ini.read(path)
    provider = dict(cred["provider"])
    changed = []
    for key in REFRESHED_KEYS:
        new = ini["r"].get(key) if ini.has_section("r") else None
        if not new or new == provider.get(key):
            continue
        try:
            token = json.loads(new)
        except ValueError:
            token = None
        if not isinstance(token, dict) or not token.get("access_token") or not token.get("refresh_token"):
            log(f"{cred['name']}: refreshed {key} looks invalid, not saved")
            continue
        provider[key] = new
        changed.append(key)
    if changed:
        midclt("cloudsync.credentials.update", str(cred["id"]), json.dumps({"provider": provider}))
        log(f"{cred['name']}: saved refreshed {', '.join(changed)}")


def cloud_status(cred):
    p = cred["provider"]
    backend, name = PROVIDERS[p["type"]]
    result = {"id": cred["id"], "provider": name}
    cfg = {
        "type": backend,
        "client_id": p.get("client_id", ""),
        "client_secret": p.get("client_secret", ""),
        "token": p["token"],
    }
    if p["type"] == "ONEDRIVE":
        cfg.update(drive_type=p["drive_type"].lower(), drive_id=p["drive_id"])
    fd, path = tempfile.mkstemp(suffix=".conf")  # mode 600: it holds the credentials
    try:
        with os.fdopen(fd, "w") as f:
            f.write("[r]\n" + "".join(f"{k} = {v}\n" for k, v in cfg.items()))
        about = json.loads(
            subprocess.check_output(
                ["rclone", "--config", path, "about", "r:", "--json"], timeout=90, stderr=subprocess.DEVNULL
            )
        )
    except (OSError, subprocess.SubprocessError, ValueError) as e:
        os.unlink(path)
        return {**result, "status": "ERROR", "error": type(e).__name__}
    # Saving the token is separate: if it fails, the space was still read correctly.
    try:
        save_refreshed_credentials(cred, path)
    except (OSError, subprocess.SubprocessError, ValueError) as e:
        log(f"{cred['name']}: could not save the refreshed token ({type(e).__name__})")
    finally:
        os.unlink(path)
    total, used = about.get("total"), about.get("used")
    free = about.get("free", total - used if total is not None and used is not None else None)
    free_pct = pct(free, total)
    status = "OK" if free_pct is None or free_pct >= WARN_PCT else "LOW" if free_pct >= CRIT_PCT else "CRITICAL"
    return {**result, "status": status, "total": total, "used": used, "free": free, "free_pct": free_pct}


def schema_regex(naming_schema):
    """Turn a TrueNAS snapshot naming schema (strftime) into a regex for snapshot names."""
    tokens = {
        "Y": r"\d{4}",
        "y": r"\d{2}",
        "m": r"\d{2}",
        "d": r"\d{2}",
        "H": r"\d{2}",
        "M": r"\d{2}",
        "S": r"\d{2}",
        "j": r"\d{3}",
        "z": r"[+-]\d{4}",
        "s": r"\d+",
        "%": "%",
    }
    parts = re.split(r"(%.)", naming_schema)
    return re.compile(
        "".join(tokens.get(x[1], r".+?") if len(x) == 2 and x[0] == "%" else re.escape(x) for x in parts) + "$"
    )


def epoch(value):
    """midclt dates look like {"$date": <milliseconds>}."""
    if isinstance(value, dict) and isinstance(value.get("$date"), (int, float)):
        return int(value["$date"] // 1000)
    return None


def scan_status(scan, now):
    """Last scrub or resilver of a pool (ZFS keeps only the most recent one)."""
    if not scan or not scan.get("function"):
        return None
    end = epoch(scan.get("end_time"))
    pct_done = scan.get("percentage")
    # Only meaningful while running (ZFS can report a bit over 100 %).
    progress = min(round(pct_done, 1), 100) if scan.get("state") == "SCANNING" and pct_done is not None else None
    return {
        "function": scan["function"],
        "state": scan.get("state"),
        "start": epoch(scan.get("start_time")),
        "end": end,
        "errors": scan.get("errors"),
        "progress_pct": progress,
        "age_hours": round((now - end) / 3600, 2) if end else None,
    }


def pool_disks(topology):
    """Every disk of a pool, from all vdev groups (data, cache, log, spare, special, dedup)."""
    disks = []

    def walk(vdev, role):
        if vdev.get("type") == "DISK":
            stats = vdev.get("stats") or {}
            disks.append(
                {
                    "name": vdev.get("disk") or vdev.get("name"),
                    "role": role,
                    "status": vdev.get("status"),
                    "read_errors": stats.get("read_errors"),
                    "write_errors": stats.get("write_errors"),
                    "checksum_errors": stats.get("checksum_errors"),
                }
            )
        for child in vdev.get("children") or []:
            walk(child, role)

    for role, vdevs in (topology or {}).items():
        for vdev in vdevs or []:
            walk(vdev, role)
    return disks


def zfs(*args):
    return subprocess.check_output(["zfs", "list", "-H", "-p", *args], text=True, timeout=120).splitlines()


def main():
    now = time.time()
    out = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "pools": {},
        "cloud": {},
        "snapshot_space": {},
        "snapshots": {},
    }

    for p in midclt("pool.query"):
        size, free = p.get("size"), p.get("free")
        out["pools"][p["name"]] = {
            "status": p.get("status"),
            "size": size,
            "free": free,
            "used": size - free if size is not None and free is not None else None,
            "free_pct": pct(free, size),
            "healthy": p.get("healthy"),
            "scan": scan_status(p.get("scan"), now),
            "disks": pool_disks(p.get("topology")),
        }

    for c in midclt("cloudsync.credentials.query"):
        if c["provider"]["type"] in PROVIDERS:
            out["cloud"][c["name"]] = cloud_status(c)

    # Space used by snapshots (usedbysnapshots) for every dataset, summed per pool.
    usedsnap = {}
    for line in zfs("-t", "filesystem,volume", "-o", "name,usedbysnapshots"):
        name, value = line.split("\t")
        usedsnap[name] = int(value) if value.isdigit() else 0
    for name, value in usedsnap.items():
        pool = name.split("/")[0]
        out["snapshot_space"][pool] = out["snapshot_space"].get(pool, 0) + value

    # Snapshots of every dataset, oldest first.
    snaps = {}
    for line in zfs("-t", "snapshot", "-o", "name,creation", "-s", "creation"):
        full, created = line.split("\t")
        dataset, snap = full.split("@", 1)
        snaps.setdefault(dataset, []).append((snap, int(created)))

    # One entry per dataset: several tasks on the same dataset (e.g. hourly and daily) are merged.
    tasks = {}
    for t in midclt("pool.snapshottask.query"):
        if t["enabled"]:
            tasks.setdefault(t["dataset"], []).append(t)
    for ds, ts in tasks.items():
        patterns = [schema_regex(t["naming_schema"]) for t in ts if t.get("naming_schema")]
        # Only snapshots created by the tasks count, manual ones do not.
        own = [(n, c) for n, c in snaps.get(ds, []) if any(r.match(n) for r in patterns)]
        recursive = any(t["recursive"] for t in ts)
        exclude = set().union(*(t.get("exclude") or [] for t in ts))
        # Size: the dataset and, if a task is recursive, its children (minus the excluded ones).
        tree = [n for n in usedsnap if n == ds or (recursive and n.startswith(ds + "/"))]
        tree = [n for n in tree if not any(n == e or n.startswith(e + "/") for e in exclude)]
        last, last_epoch = own[-1] if own else (None, None)
        out["snapshots"][ds] = {
            "tasks": sorted(t["id"] for t in ts),
            "recursive": recursive,
            "count": len(own),
            "bytes": sum(usedsnap[n] for n in tree),
            "last": last,
            "last_epoch": last_epoch,
            "age_hours": round((now - last_epoch) / 3600, 2) if last_epoch else None,
        }

    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT)


if __name__ == "__main__":
    main()
