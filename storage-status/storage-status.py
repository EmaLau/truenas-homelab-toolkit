#!/usr/bin/env python3
"""Pool health and space, cloud storage space, cloud sync results and snapshot
task status -> one JSON file for dashboards, optionally a Prometheus textfile.

Settings: storage-status.conf next to this script (see storage-status.conf.example),
or the file named by $STORAGE_STATUS_CONF; environment variables override it.
Schema: docs/storage-status.schema.json. Values are raw numbers (bytes, Unix
timestamps, hours): formatting is left to the dashboard. Each section is
collected on its own: if one fails, the file is still written, the error is
listed in "errors" and the script exits with status 1.
"""

import configparser
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from datetime import datetime

SCHEMA_VERSION = 1
DEFAULTS = {
    "STORAGE_STATUS_OUT": "/var/tmp/storage_status.json",
    "PROMETHEUS_OUT": "",  # e.g. /var/lib/node_exporter/textfile/storage_status.prom
    "WARN_PCT": "20",  # free space below this -> LOW
    "CRIT_PCT": "10",  # free space below this -> CRITICAL
}
# TrueNAS cloud credential type -> (rclone backend, name used in the JSON).
# Other providers are skipped: not every rclone backend reports free space.
PROVIDERS = {"ONEDRIVE": ("onedrive", "onedrive"), "GOOGLE_DRIVE": ("drive", "google_drive")}
# rclone may refresh these during "about"; like TrueNAS after a cloud sync, save them back.
REFRESHED_KEYS = ("token",)
SECTIONS = ("pools", "cloud", "cloud_sync", "snapshots")


def load_settings():
    """KEY="value" lines from the settings file, then the environment."""
    path = os.environ.get("STORAGE_STATUS_CONF") or os.path.join(
        os.path.dirname(os.path.realpath(__file__)), "storage-status.conf"
    )
    cfg = dict(DEFAULTS)
    if os.path.exists(path):
        with open(path) as f:
            for n, line in enumerate(f, 1):
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                key, sep, value = line.partition("=")
                key = key.strip()
                if not sep or key not in DEFAULTS:
                    raise SystemExit(f"storage-status: {path}:{n}: unknown setting {key!r}")
                cfg[key] = " ".join(shlex.split(value, comments=True))
    for key in DEFAULTS:
        if os.environ.get(key):
            cfg[key] = os.environ[key]
    try:
        warn, crit = int(cfg["WARN_PCT"]), int(cfg["CRIT_PCT"])
    except ValueError:
        raise SystemExit("storage-status: WARN_PCT and CRIT_PCT must be whole numbers") from None
    if not 0 <= crit < warn <= 100:
        raise SystemExit("storage-status: thresholds must satisfy 0 <= CRIT_PCT < WARN_PCT <= 100")
    cfg["WARN_PCT"], cfg["CRIT_PCT"] = warn, crit
    return cfg


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


def space_level(free_pct, cfg):
    if free_pct is None:
        return None
    return "OK" if free_pct >= cfg["WARN_PCT"] else "LOW" if free_pct >= cfg["CRIT_PCT"] else "CRITICAL"


def cloud_status(cred, cfg):
    p = cred["provider"]
    backend, name = PROVIDERS[p["type"]]
    result = {"id": cred["id"], "provider": name}
    rclone_cfg = {
        "type": backend,
        "client_id": p.get("client_id", ""),
        "client_secret": p.get("client_secret", ""),
        "token": p["token"],
    }
    if p["type"] == "ONEDRIVE":
        rclone_cfg.update(drive_type=p["drive_type"].lower(), drive_id=p["drive_id"])
    fd, path = tempfile.mkstemp(suffix=".conf")  # mode 600: it holds the credentials
    try:
        with os.fdopen(fd, "w") as f:
            f.write("[r]\n" + "".join(f"{k} = {v}\n" for k, v in rclone_cfg.items()))
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
    status = space_level(free_pct, cfg) or "OK"
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


def cloud_sync_tasks(now):
    """Last run of every cloud sync task, by description."""
    out = {}
    for t in midclt("cloudsync.query"):
        job = t.get("job") or {}
        finished = epoch(job.get("time_finished"))
        cred = t.get("credentials")
        name = t.get("description") or f"task {t['id']}"
        if name in out:
            name = f"{name} ({t['id']})"
        error = job.get("error")
        out[name] = {
            "id": t["id"],
            "credential": cred.get("name") if isinstance(cred, dict) else None,
            "direction": t.get("direction"),
            "enabled": t.get("enabled"),
            "state": job.get("state"),
            "started": epoch(job.get("time_started")),
            "finished": finished,
            "age_hours": round((now - finished) / 3600, 2) if finished else None,
            "error": str(error)[:300] if error else None,
        }
    return out


def pools_status(now, cfg):
    out = {}
    for p in midclt("pool.query"):
        size, free = p.get("size"), p.get("free")
        free_pct = pct(free, size)
        out[p["name"]] = {
            "status": p.get("status"),
            "size": size,
            "free": free,
            "used": size - free if size is not None and free is not None else None,
            "free_pct": free_pct,
            "space_status": space_level(free_pct, cfg),
            "healthy": p.get("healthy"),
            "scan": scan_status(p.get("scan"), now),
            "disks": pool_disks(p.get("topology")),
        }
    return out


def snapshots_status(now):
    """Space used by snapshots per pool, and the state of every snapshot task."""
    usedsnap = {}
    for line in zfs("-t", "filesystem,volume", "-o", "name,usedbysnapshots"):
        name, value = line.split("\t")
        usedsnap[name] = int(value) if value.isdigit() else 0
    space = {}
    for name, value in usedsnap.items():
        pool = name.split("/")[0]
        space[pool] = space.get(pool, 0) + value

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
    out = {}
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
        out[ds] = {
            "tasks": sorted(t["id"] for t in ts),
            "recursive": recursive,
            "count": len(own),
            "bytes": sum(usedsnap[n] for n in tree),
            "last": last,
            "last_epoch": last_epoch,
            "age_hours": round((now - last_epoch) / 3600, 2) if last_epoch else None,
        }
    return space, out


def prom_escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def prometheus(out):
    """The same data as Prometheus metrics, for node_exporter's textfile collector."""
    metrics = {}  # name -> (help, [(labels, value)])

    def add(name, help_text, labels, value):
        if value is None:
            return
        if isinstance(value, bool):
            value = int(value)
        metrics.setdefault(name, (help_text, []))[1].append((labels, value))

    add("generated_timestamp_seconds", "When the data was collected.", {}, out["generated_epoch"])
    for section in SECTIONS:
        add(
            "section_ok",
            "1 if the section was collected without errors.",
            {"section": section},
            section not in out["errors"],
        )
    for pool, p in out["pools"].items():
        lp = {"pool": pool}
        add("pool_size_bytes", "Pool size.", lp, p["size"])
        add("pool_free_bytes", "Free space in the pool.", lp, p["free"])
        add("pool_healthy", "1 if TrueNAS reports the pool as healthy.", lp, p["healthy"])
        add("pool_online", "1 if the pool status is ONLINE.", lp, p["status"] == "ONLINE")
        scan = p["scan"] or {}
        add("pool_scan_errors", "Errors found by the last scrub or resilver.", lp, scan.get("errors"))
        add("pool_scan_end_timestamp_seconds", "End of the last scrub or resilver.", lp, scan.get("end"))
        add(
            "pool_scan_running",
            "1 while a scrub or resilver is running.",
            lp,
            scan.get("state") == "SCANNING" if scan else None,
        )
        for d in p["disks"]:
            ld = {"pool": pool, "disk": d["name"]}
            add("disk_online", "1 if the disk status is ONLINE.", ld, d["status"] == "ONLINE")
            for kind in ("read", "write", "checksum"):
                add(
                    "disk_errors",
                    "ZFS error counters of the disk (reset by zpool clear).",
                    {**ld, "type": kind},
                    d[f"{kind}_errors"],
                )
    for name, c in out["cloud"].items():
        lc = {"credential": name, "provider": c["provider"]}
        add("cloud_up", "1 if the cloud space could be read.", lc, c["status"] != "ERROR")
        add("cloud_total_bytes", "Cloud storage size.", lc, c.get("total"))
        add("cloud_used_bytes", "Cloud storage used.", lc, c.get("used"))
        add("cloud_free_bytes", "Cloud storage free.", lc, c.get("free"))
    for name, t in out["cloud_sync"].items():
        lt = {"task": name, "id": t["id"]}
        if t["state"] is not None:
            add("cloudsync_success", "1 if the last run of the cloud sync task succeeded.", lt, t["state"] == "SUCCESS")
            add("cloudsync_running", "1 while the cloud sync task is running.", lt, t["state"] == "RUNNING")
        add("cloudsync_finished_timestamp_seconds", "End of the last run of the cloud sync task.", lt, t["finished"])
    for pool, value in out["snapshot_space"].items():
        add("snapshot_space_bytes", "Space used by snapshots in the pool.", {"pool": pool}, value)
    for ds, s in out["snapshots"].items():
        ls = {"dataset": ds}
        add("snapshots", "Snapshots created by the periodic snapshot tasks.", ls, s["count"])
        add("snapshots_bytes", "Space used by the snapshots of the dataset.", ls, s["bytes"])
        add("snapshot_last_timestamp_seconds", "Creation time of the newest snapshot.", ls, s["last_epoch"])

    lines = []
    for name, (help_text, samples) in metrics.items():
        full = f"storage_status_{name}"
        lines += [f"# HELP {full} {help_text}", f"# TYPE {full} gauge"]
        for labels, value in samples:
            lab = ",".join(f'{k}="{prom_escape(v)}"' for k, v in labels.items())
            lines.append(f"{full}{{{lab}}} {value}" if lab else f"{full} {value}")
    return "\n".join(lines) + "\n"


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def main():
    cfg = load_settings()
    now = time.time()
    out = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "generated_epoch": int(now),
        "thresholds": {"warn_pct": cfg["WARN_PCT"], "crit_pct": cfg["CRIT_PCT"]},
        "errors": {},
        "pools": {},
        "cloud": {},
        "cloud_sync": {},
        "snapshot_space": {},
        "snapshots": {},
    }

    def section(name, collect):
        try:
            collect()
        except Exception as e:  # noqa: BLE001 - one failing section must not stop the others
            out["errors"][name] = f"{type(e).__name__}: {e}"[:300]
            log(f"{name}: {out['errors'][name]}")

    def cloud():
        for c in midclt("cloudsync.credentials.query"):
            if c["provider"]["type"] in PROVIDERS:
                out["cloud"][c["name"]] = cloud_status(c, cfg)

    def snapshots():
        out["snapshot_space"], out["snapshots"] = snapshots_status(now)

    section("pools", lambda: out.update(pools=pools_status(now, cfg)))
    section("cloud", cloud)
    section("cloud_sync", lambda: out.update(cloud_sync=cloud_sync_tasks(now)))
    section("snapshots", snapshots)

    write_atomic(cfg["STORAGE_STATUS_OUT"], json.dumps(out, ensure_ascii=False, indent=1))
    if cfg["PROMETHEUS_OUT"]:
        write_atomic(cfg["PROMETHEUS_OUT"], prometheus(out))
    return 1 if out["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
