#!/bin/bash
# Tests for install.sh with a fake midclt that keeps cron jobs and init scripts
# in JSON files. Needs bash 5 and python3:
#
#   bash tests/install-test.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
FAIL=0
export STATE="$T/state"
mkdir -p "$T/bin" "$STATE"

cat >"$T/bin/midclt" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
state = os.environ["STATE"]
_, method, *args = sys.argv[1:]
api, op = method.rsplit(".", 1)
path = os.path.join(state, api + ".json")
items = json.load(open(path)) if os.path.exists(path) else []
with open(os.path.join(state, "calls"), "a") as f:
    f.write(method + "\n")
if op == "query":
    print(json.dumps(items))
    sys.exit()
if op == "create":
    item = json.loads(args[0])
    item["id"] = max([i["id"] for i in items] + [100]) + 1
    items.append(item)
elif op == "update":
    for i in items:
        if i["id"] == int(args[0]):
            i.update(json.loads(args[1]))
elif op == "delete":
    items = [i for i in items if i["id"] != int(args[0])]
json.dump(items, open(path, "w"))
print("{}")
EOF
chmod +x "$T/bin/midclt"
export PATH="$T/bin:$PATH"
export TRUENAS_VERSION_FILE="$T/version"
echo 25.10.8 >"$TRUENAS_VERSION_FILE"

check() {
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; FAIL=1; fi
}
toolkit() {   # copy of the toolkit in $1
    mkdir -p "$1"
    cp -r "$SRC/install.sh" "$SRC/lan-guard" "$SRC/heartbeat" "$SRC/storage-status" "$SRC/system-backup" "$1/"
    rm -f "$1"/*/*.conf
}
inst() { bash "$R/install.sh" "$@" >"$T/out" 2>&1; }
q() {   # q <api> <python expression over the list "j">
    python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print($2)" "$STATE/$1.json" 2>/dev/null || echo none
}
mine() { q "$1" "len([x for x in j if x.get('description', x.get('comment', '')).startswith('truenas-homelab-toolkit: ')])"; }

R="$T/toolkit"
toolkit "$R"
inst; check "no settings file: exit code 1" 1 $?
check "no settings file: message" 1 "$(grep -c 'no settings file found' "$T/out")"
inst --bogus; check "unknown argument: exit code 2" 2 $?

printf 'LAN_IF="eth0"\nPORTS=(30001)\n' >"$R/lan-guard/lan-guard.conf"
printf 'HEALTHCHECKS_URL="https://hc.example/x"\n' >"$R/heartbeat/heartbeat.conf"
# A job made by hand that already runs heartbeat.
echo '[{"id": 5, "command": "/bin/bash /mnt/Apps/Old/heartbeat.sh", "description": "my heartbeat", "enabled": true,
        "user": "root", "schedule": {"minute": "*", "hour": "*", "dom": "*", "month": "*", "dow": "*"}, "stdout": true, "stderr": false}]' \
    >"$STATE/cronjob.json"

inst --dry-run; check "dry run: exit code" 0 $?
check "dry run: three jobs planned" 3 "$(grep -c '^create' "$T/out")"
check "dry run: nothing created" "1 none" "$(q cronjob 'len(j)') $(q initshutdownscript 'len(j)')"
check "dry run: job made by hand reported" 1 "$(grep -c "WARNING: cron job 5 ('my heartbeat') also runs heartbeat.sh" "$T/out")"

inst; check "install: exit code" 0 $?
check "install: cron jobs (toolkit) and init script" "2 1" "$(mine cronjob) $(mine initshutdownscript)"
check "install: job made by hand untouched" "my heartbeat" "$(q cronjob "[x['description'] for x in j if x['id'] == 5][0]")"
check "install: lan-guard cron" "*/5 root True True False" \
    "$(q cronjob "[' '.join(map(str, (x['schedule']['minute'], x['user'], x['enabled'], x['stdout'], x['stderr']))) for x in j if x['description'].endswith('lan-guard')][0]")"
check "install: lan-guard at boot" "POSTINIT COMMAND /bin/bash $R/lan-guard/lan-guard.sh apply" \
    "$(q initshutdownscript "' '.join((j[0]['when'], j[0]['type'], j[0]['command']))")"

inst; check "again: no changes" "3 0" "$(grep -c '^ok ' "$T/out") $(grep -c '^create\|^update' "$T/out")"
check "again: no copies" "2 1" "$(mine cronjob) $(mine initshutdownscript)"

R2="$T/moved"
toolkit "$R2"
cp "$R/lan-guard/lan-guard.conf" "$R2/lan-guard/"; cp "$R/heartbeat/heartbeat.conf" "$R2/heartbeat/"
R="$R2" inst
check "moved folder: jobs updated, not copied" "3 2 1" "$(grep -c '^update' "$T/out") $(mine cronjob) $(mine initshutdownscript)"
check "moved folder: new path" 3 "$(cat "$STATE"/*.json | grep -o "$R2/" | wc -l)"
R="$R2"

inst --disabled storage-status
check "--disabled: storage-status created off" False "$(q cronjob "[x['enabled'] for x in j if x['description'].endswith('storage-status')][0]")"

echo 24.04.2 >"$TRUENAS_VERSION_FILE"; inst --dry-run
check "untested version: warning" 1 "$(grep -c 'TrueNAS 24.04.2 has not been tested' "$T/out")"
echo 25.10.8 >"$TRUENAS_VERSION_FILE"; inst --dry-run
check "tested version: no warning" 0 "$(grep -c 'has not been tested' "$T/out" || true)"

inst system-backup; check "missing settings file for a named script: exit code 1" 1 $?
printf 'LAN_IF="eth0"\nPORTS=(nope)\n' >"$R/lan-guard/lan-guard.conf"
: >"$STATE/calls"
inst lan-guard; check "invalid lan-guard.conf: exit code 1, nothing called" "1 0" "$? $(grep -c 'create\|update' "$STATE/calls" || true)"

inst --uninstall; check "uninstall: exit code" 0 $?
check "uninstall: toolkit jobs removed, job made by hand kept" "0 0 1" "$(mine cronjob) $(mine initshutdownscript) $(q cronjob 'len(j)')"

if [ "$FAIL" -ne 0 ]; then echo "--- last output"; cat "$T/out"; echo "some install tests FAILED"; exit 1; fi
echo "all install tests passed"
