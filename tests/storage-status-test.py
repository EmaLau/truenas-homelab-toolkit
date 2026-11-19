#!/usr/bin/env python3
"""Tests for storage-status with fake midclt, zfs and rclone (tests/storage-status.fixtures.json).

    python3 tests/storage-status-test.py [OUTPUT_DIR]

The JSON files written by the scenarios are kept in OUTPUT_DIR (default: a
temporary folder), so CI can validate them against the schema afterwards.
"""

import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "storage-status", "storage-status.py")
FIXTURES = os.path.join(HERE, "storage-status.fixtures.json")

FAKE_MIDCLT = """
import json, os, sys
fx = json.load(open(os.environ["FIXTURES"]))["midclt"]
method, args = sys.argv[2], sys.argv[3:]
if method in os.environ.get("FAIL_METHODS", "").split(","):
    sys.exit(f"fake midclt: {method} failed")
if method == "cloudsync.credentials.update":
    with open(os.environ["CALL_LOG"], "a") as f:
        f.write(json.dumps([method, *args]) + "\\n")
    print("{}")
else:
    print(json.dumps(fx[method]))
"""

FAKE_ZFS = """
import json, os, sys
fx = json.load(open(os.environ["FIXTURES"]))
sys.stdout.write(fx["zfs_snapshots"] if "snapshot" in sys.argv else fx["zfs_filesystems"])
"""

# rclone: answers "about" from the fixtures and, like the real one, refreshes
# the OneDrive token in the config file it was given.
FAKE_RCLONE = """
import json, os, re, sys
fx = json.load(open(os.environ["FIXTURES"]))
conf = sys.argv[sys.argv.index("--config") + 1]
text = open(conf).read()
backend = re.search(r"^type = (\\S+)", text, re.M).group(1)
if backend == "onedrive":
    new = json.dumps({"access_token": "new", "refresh_token": "r1-rotated"})
    open(conf, "w").write(re.sub(r"^token = .*$", "token = " + new, text, flags=re.M))
print(json.dumps(fx["rclone_about"][backend]))
"""

FAILED = []


def read(path):
    with open(path) as f:
        return f.read()


def check(desc, expected, actual):
    if expected == actual:
        print(f"ok   {desc}")
    else:
        print(f"FAIL {desc}: expected {expected!r}, got {actual!r}")
        FAILED.append(desc)


def make_bin(folder):
    for name, code in (("midclt", FAKE_MIDCLT), ("zfs", FAKE_ZFS), ("rclone", FAKE_RCLONE)):
        path = os.path.join(folder, name)
        with open(path, "w") as f:
            f.write(f"#!{sys.executable}\n{code}")
        os.chmod(path, 0o755)


def run(work, conf, out_json, fail=""):
    conf_path = os.path.join(work, "storage-status.conf")
    with open(conf_path, "w") as f:
        f.write(conf)
    env = {
        **os.environ,
        "PATH": os.path.join(work, "bin") + os.pathsep + os.environ["PATH"],
        "FIXTURES": FIXTURES,
        "CALL_LOG": os.path.join(work, "calls.log"),
        "FAIL_METHODS": fail,
        "STORAGE_STATUS_CONF": conf_path,
        "STORAGE_STATUS_OUT": out_json,
    }
    for key in ("PROMETHEUS_OUT", "WARN_PCT", "CRIT_PCT"):
        env.pop(key, None)
    for path in (out_json, env["CALL_LOG"]):
        if os.path.exists(path):
            os.unlink(path)
    return subprocess.run([sys.executable, SCRIPT], check=False, env=env, capture_output=True, text=True)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp()
    os.makedirs(out_dir, exist_ok=True)
    work = tempfile.mkdtemp()
    os.mkdir(os.path.join(work, "bin"))
    make_bin(os.path.join(work, "bin"))
    prom_path = os.path.join(work, "storage_status.prom")

    # 1. Everything works; thresholds from the settings file.
    normal = os.path.join(out_dir, "normal.json")
    r = run(work, f'WARN_PCT="50"\nCRIT_PCT=10  # comment\nPROMETHEUS_OUT="{prom_path}"\n', normal)
    check("normal: exit code", 0, r.returncode)
    d = json.loads(read(normal))
    check("normal: no errors", {}, d["errors"])
    check("normal: thresholds", {"warn_pct": 50, "crit_pct": 10}, d["thresholds"])
    pools = d["pools"]
    check(
        "pools: space status from thresholds",
        ["LOW", "CRITICAL", None],
        [pools[p]["space_status"] for p in ("tank", "fast", "offline")],
    )
    check("pools: size 0 gives free_pct null", None, pools["offline"]["free_pct"])
    check(
        "pools: disks from data and cache",
        [("sda", "data"), ("sdb", "data"), ("nvme0n1", "cache")],
        [(x["name"], x["role"]) for x in pools["tank"]["disks"]],
    )
    check("pools: checksum errors", 2, pools["tank"]["disks"][1]["checksum_errors"])
    check(
        "pools: missing disk named by its vdev",
        ("1234567890", "UNAVAIL"),
        (pools["fast"]["disks"][1]["name"], pools["fast"]["disks"][1]["status"]),
    )
    check(
        "pools: finished scrub",
        ("SCRUB", 0, None, 1795003600),
        tuple(pools["tank"]["scan"][k] for k in ("function", "errors", "progress_pct", "end")),
    )
    check(
        "pools: running resilver",
        (42.5, None, None),
        tuple(pools["fast"]["scan"][k] for k in ("progress_pct", "end", "age_hours")),
    )
    check("pools: no scan, no topology", (None, []), (pools["offline"]["scan"], pools["offline"]["disks"]))

    cloud = d["cloud"]
    check("cloud: unsupported provider skipped", ['My "OneDrive"', "Drive"], list(cloud))
    check(
        "cloud: status from thresholds",
        ("CRITICAL", 5, "OK", 90),
        (
            cloud['My "OneDrive"']["status"],
            cloud['My "OneDrive"']["free_pct"],
            cloud["Drive"]["status"],
            cloud["Drive"]["free_pct"],
        ),
    )
    calls = [json.loads(x) for x in read(os.path.join(work, "calls.log")).splitlines()]
    check("cloud: only the refreshed token is saved", [["cloudsync.credentials.update", "1"]], [c[:2] for c in calls])
    saved = json.loads(json.loads(calls[0][2])["provider"]["token"])
    check("cloud: saved token is the new one", "r1-rotated", saved["refresh_token"])

    sync = d["cloud_sync"]
    check(
        "cloud sync: tasks, duplicate description gets the id",
        ["Documents to OneDrive", "Photos", "Photos (3)"],
        list(sync),
    )
    check(
        "cloud sync: success",
        ("SUCCESS", None, 1795064450),
        tuple(sync["Documents to OneDrive"][k] for k in ("state", "error", "finished")),
    )
    check(
        "cloud sync: failure keeps the error",
        ("FAILED", "[EFAULT] rclone failed"),
        (sync["Photos"]["state"], sync["Photos"]["error"]),
    )
    check(
        "cloud sync: never run",
        (None, None, False),
        tuple(sync["Photos (3)"][k] for k in ("state", "finished", "enabled")),
    )

    snaps = d["snapshots"]
    check("snapshots: disabled task skipped", ["tank/data", "tank/apps"], list(snaps))
    check(
        "snapshots: two tasks merged, manual snapshot not counted",
        ([1, 2], 2, "weekly-2026-11-19"),
        (snaps["tank/data"]["tasks"], snaps["tank/data"]["count"], snaps["tank/data"]["last"]),
    )
    check("snapshots: recursive size minus excluded child", 150, snaps["tank/apps"]["bytes"])
    check("snapshot space per pool", {"tank": 1449, "boot-pool": 7}, d["snapshot_space"])

    prom = read(prom_path)
    sample = re.compile(r'^storage_status_[a-z_]+(\{([a-z_]+="([^"\\]|\\.)*",?)*\})? -?[0-9.e+]+$')
    bad = [x for x in prom.splitlines() if not x.startswith("# ") and not sample.match(x)]
    check("prometheus: every sample is well formed", [], bad)
    for line in (
        'storage_status_pool_healthy{pool="fast"} 0',
        'storage_status_pool_scan_running{pool="fast"} 1',
        'storage_status_disk_errors{pool="tank",disk="sdb",type="checksum"} 2',
        'storage_status_cloud_free_bytes{credential="My \\"OneDrive\\"",provider="onedrive"} 50',
        'storage_status_cloudsync_success{task="Photos",id="2"} 0',
        'storage_status_snapshots{dataset="tank/data"} 2',
        'storage_status_section_ok{section="pools"} 1',
    ):
        check(f"prometheus: {line}", True, line in prom.splitlines())
    check(
        "prometheus: one TYPE line per metric",
        len(set(re.findall(r"^# TYPE (\S+)", prom, re.MULTILINE))),
        len(re.findall(r"^# TYPE ", prom, re.MULTILINE)),
    )

    # 2. One section fails: the file is still written, the others are complete.
    failing = os.path.join(out_dir, "failing.json")
    r = run(work, f'PROMETHEUS_OUT="{prom_path}"\n', failing, fail="pool.query")
    check("failing section: exit code 1", 1, r.returncode)
    d = json.loads(read(failing))
    check("failing section: error recorded", ["pools"], list(d["errors"]))
    check(
        "failing section: other sections complete",
        (0, 2, 3, 2),
        (len(d["pools"]), len(d["cloud"]), len(d["cloud_sync"]), len(d["snapshots"])),
    )
    check("failing section: default thresholds", {"warn_pct": 20, "crit_pct": 10}, d["thresholds"])
    check(
        "failing section: reported to Prometheus",
        True,
        'storage_status_section_ok{section="pools"} 0' in read(prom_path).splitlines(),
    )

    # 3. Bad settings: stop before writing anything.
    for desc, conf in (
        ("thresholds in the wrong order", "WARN_PCT=5\nCRIT_PCT=10\n"),
        ("non-numeric threshold", "WARN_PCT=high\n"),
        ("unknown setting", "WARN=20\n"),
    ):
        bad_out = os.path.join(work, "bad.json")
        r = run(work, conf, bad_out)
        check(
            f"bad settings ({desc}): stops with an error", (True, False), (r.returncode != 0, os.path.exists(bad_out))
        )

    if FAILED:
        print(f"{len(FAILED)} storage-status tests FAILED")
        sys.exit(1)
    print("all storage-status tests passed")


if __name__ == "__main__":
    main()
