#!/bin/bash
# install.sh: create the TrueNAS cron jobs and init scripts for the toolkit,
# through the middleware (the same as System → Advanced in the web UI).
#
#   install.sh [--dry-run] [--disabled] [SCRIPT...]   create or update the jobs
#   install.sh --uninstall [--dry-run] [SCRIPT...]    remove them
#
# SCRIPT: lan-guard heartbeat storage-status system-backup system-backup-verify.
# Without SCRIPT: every script that has its settings file. Jobs are recognised by
# their description ("truenas-homelab-toolkit: <script>"), so running install.sh
# again updates them (e.g. after moving the folder) instead of adding copies.
# Jobs made by hand that run the same script are reported, not touched.
# --disabled creates the jobs switched off, to review them in the UI first.
set -euo pipefail
ROOT="$(dirname "$(readlink -f "$0")")"
TESTED_VERSIONS="25.10"   # TrueNAS versions the toolkit runs on (prefixes)
VERSION_FILE="${TRUENAS_VERSION_FILE:-/etc/version}"

DRY=no; ENABLED=true; UNINSTALL=no; WANT=()
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=yes ;;
        --disabled) ENABLED=false ;;
        --uninstall) UNINSTALL=yes ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        lan-guard|heartbeat|storage-status|system-backup|system-backup-verify) WANT+=("$a") ;;
        *) echo "install.sh: unknown argument '$a' (see --help)" >&2; exit 2 ;;
    esac
done

command -v midclt >/dev/null || { echo "install.sh: midclt not found: run this on TrueNAS, as root" >&2; exit 1; }
if [ -r "$VERSION_FILE" ]; then
    V="$(cat "$VERSION_FILE")"
    ok=no; for t in $TESTED_VERSIONS; do [[ "$V" == "$t"* ]] && ok=yes; done
    [ "$ok" = yes ] || echo "install.sh: WARNING: TrueNAS $V has not been tested (tested: $TESTED_VERSIONS); check each script after installing" >&2
fi
[[ "$ROOT" == /mnt/* ]] || echo "install.sh: WARNING: $ROOT is not under /mnt: keep the toolkit on a data pool, the boot pool is replaced on updates" >&2

# Schedules can be changed in toolkit.conf: SCHEDULE_LAN_GUARD, SCHEDULE_HEARTBEAT,
# SCHEDULE_STORAGE_STATUS, SCHEDULE_SYSTEM_BACKUP, SCHEDULE_SYSTEM_BACKUP_VERIFY.
TK="${TOOLKIT_CONF:-$ROOT/toolkit.conf}"
# shellcheck source=/dev/null
[ -f "$TK" ] && . "$TK"
sched() {   # sched <script name> <default>: the schedule from toolkit.conf, or the default
    local v="SCHEDULE_${1//-/_}"; v="${v^^}"
    local s="${!v:-$2}"
    [[ "$s" =~ ^[^[:space:]]+( [^[:space:]]+){4}$ ]] || { echo "install.sh: $v must have 5 cron fields (now: '$s')" >&2; exit 1; }
    echo "$s"
}

S_LG=$(sched lan-guard '*/5 * * * *') || exit 1
S_HB=$(sched heartbeat '* * * * *') || exit 1
S_SS=$(sched storage-status '*/30 * * * *') || exit 1
S_SB=$(sched system-backup '0 3 * * *') || exit 1
S_SV=$(sched system-backup-verify '0 5 * * 0') || exit 1

# name|settings file (empty: optional)|kind|schedule or when|command
JOBS=(
    "lan-guard|lan-guard/lan-guard.conf|init|POSTINIT|/bin/bash $ROOT/lan-guard/lan-guard.sh apply"
    "lan-guard|lan-guard/lan-guard.conf|cron|$S_LG|/bin/bash $ROOT/lan-guard/lan-guard.sh apply"
    "heartbeat|heartbeat/heartbeat.conf|cron|$S_HB|/bin/bash $ROOT/heartbeat/heartbeat.sh"
    "storage-status||cron|$S_SS|/usr/bin/python3 $ROOT/storage-status/storage-status.py"
    "system-backup|system-backup/system-backup.conf|cron|$S_SB|/bin/bash $ROOT/system-backup/system-backup.sh"
    "system-backup-verify|system-backup/system-backup.conf|cron|$S_SV|/bin/bash $ROOT/system-backup/system-backup-verify.sh --restore"
)

if [ "${#WANT[@]}" -eq 0 ]; then
    for J in "${JOBS[@]}"; do
        IFS='|' read -r name conf _ <<<"$J"
        [ -n "$conf" ] && [ -f "$ROOT/$conf" ] && [[ " ${WANT[*]-} " != *" $name "* ]] && WANT+=("$name")
    done
    [ "$UNINSTALL" = yes ] && WANT=(lan-guard heartbeat storage-status system-backup system-backup-verify)
    [ "${#WANT[@]}" -gt 0 ] || { echo "install.sh: no settings file found; copy the *.conf.example you need, or name the scripts (see --help)" >&2; exit 1; }
fi

# Settings must exist and be valid before anything is created.
if [ "$UNINSTALL" = no ]; then
    for J in "${JOBS[@]}"; do
        IFS='|' read -r name conf _ <<<"$J"
        [[ " ${WANT[*]} " == *" $name "* ]] || continue
        if [ -n "$conf" ] && [ ! -f "$ROOT/$conf" ]; then
            echo "install.sh: $name needs $conf (copy it from $conf.example)" >&2; exit 1
        fi
    done
    if [[ " ${WANT[*]} " == *" lan-guard "* ]] && ! bash "$ROOT/lan-guard/lan-guard.sh" dry-run >/dev/null; then
        echo "install.sh: lan-guard.conf is not valid (see the error above)" >&2; exit 1
    fi
fi

# All middleware work in one Python process: read the current jobs, plan, apply.
midclt call cronjob.query >"${TMPDIR:-/tmp}/tk-cron.$$"
midclt call initshutdownscript.query >"${TMPDIR:-/tmp}/tk-init.$$"
trap 'rm -f "${TMPDIR:-/tmp}"/tk-cron.$$ "${TMPDIR:-/tmp}"/tk-init.$$' EXIT
python3 - "$DRY" "$ENABLED" "$UNINSTALL" "${TMPDIR:-/tmp}/tk-cron.$$" "${TMPDIR:-/tmp}/tk-init.$$" "${WANT[*]}" "${JOBS[@]}" <<'PY'
import json, re, subprocess, sys

dry, enabled, uninstall = sys.argv[1] == "yes", sys.argv[2] == "true", sys.argv[3] == "yes"
cron = json.load(open(sys.argv[4]))
init = json.load(open(sys.argv[5]))
want = sys.argv[6].split()
jobs = [j.split("|", 4) for j in sys.argv[7:]]
PREFIX = "truenas-homelab-toolkit: "

def call(*args):
    print("  midclt call " + " ".join(args[:2]) + (" ..." if len(args) > 2 else ""))
    if not dry:
        subprocess.run(["midclt", "call", *args], check=True, stdout=subprocess.DEVNULL)

def script_of(command):
    m = re.search(r"([\w.-]+\.(?:sh|py))\b", command or "")
    return m.group(1) if m else None

changed = 0
for kind, existing, api in (("cron", cron, "cronjob"), ("init", init, "initshutdownscript")):
    label = "description" if kind == "cron" else "comment"
    for name in want:
        mine = [j for j in jobs if j[0] == name and j[2] == kind]
        tag = PREFIX + name
        found = [e for e in existing if e.get(label) == tag]
        if uninstall:
            for e in found:
                print(f"remove {kind} job {e['id']} ({tag})")
                call(f"{api}.delete", str(e["id"]))
                changed += 1
            continue
        for _, _, _, when, command in mine:
            if kind == "cron":
                minute, hour, dom, month, dow = when.split()
                body = {"command": command, "description": tag, "enabled": enabled, "user": "root",
                        "schedule": {"minute": minute, "hour": hour, "dom": dom, "month": month, "dow": dow},
                        "stdout": True, "stderr": False}
            else:
                body = {"type": "COMMAND", "command": command, "when": when, "enabled": enabled,
                        "timeout": 30, "comment": tag}
            # Jobs made by hand that run the same script would run it twice.
            for e in existing:
                if e.get(label) != tag and script_of(e.get("command") or e.get("script")) == script_of(command):
                    print(f"WARNING: {kind} job {e['id']} ('{e.get(label)}') also runs {script_of(command)}: "
                          "remove it in System → Advanced, or the script runs twice")
            if found:
                same = all(found[0].get(k) == v for k, v in body.items())
                if same:
                    print(f"ok     {kind} job {found[0]['id']} ({tag})")
                    continue
                print(f"update {kind} job {found[0]['id']} ({tag})")
                call(f"{api}.update", str(found[0]["id"]), json.dumps(body))
            else:
                print(f"create {kind} job ({tag}): {when}  {command}")
                call(f"{api}.create", json.dumps(body))
            changed += 1
note = ", jobs created disabled" if changed and not (enabled or uninstall) else ""
print(("dry run: nothing changed" if dry else f"{changed} change(s)") + note)
PY
