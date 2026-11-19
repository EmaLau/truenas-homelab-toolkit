#!/bin/bash
# Tests for system-backup and system-backup-verify with fake midclt and curl
# (the TrueNAS parts). Database dumps are covered by system-backup-restore-test.sh.
# Needs bash 5, GNU coreutils/tar/find, flock, python3:
#
#   bash tests/system-backup-test.sh
#   docker run --rm -v "$PWD":/src:ro python:3.13-alpine \
#     sh -c 'apk add -q bash coreutils tar findutils util-linux && bash /src/tests/system-backup-test.sh'
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
FAIL=0
export FAKE="$T/fake"
mkdir -p "$T/bin" "$FAKE"

# A config.save like TrueNAS makes: a tar with the SQLite database and the secret seed.
mkdir -p "$T/cfg"
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("create table system_settings (id int)"); c.commit()' "$T/cfg/freenas-v1.db"
echo seed >"$T/cfg/pwenc_secret"
tar -cf "$FAKE/config-good.tar" -C "$T/cfg" freenas-v1.db pwenc_secret
tar -cf "$FAKE/config-noseed.tar" -C "$T/cfg" freenas-v1.db

cat >"$T/bin/midclt" <<'EOF'
#!/bin/bash
[ "$1" = call ] && shift
[ "$1" = -j ] && shift
m="$1"; shift
echo "midclt $m $*" >>"$FAKE/calls"
case "$m" in
    system.version) echo '"25.10.8"' ;;
    core.download) echo '[7, "/_download/7?auth=x"]' ;;
    app.query) python3 -c 'import json,sys; print(json.dumps([{"name": n} for n in sys.argv[1:]]))' $FAKE_APPS ;;
    app.config) [[ " ${FAIL_CONFIG:-} " == *" $1 "* ]] && exit 1; echo '{"values": {"x": 1}}' ;;
    app.get_instance) printf '{"name": "%s", "state": "%s"}\n' "$1" "$(cat "$FAKE/state-$1" 2>/dev/null || echo RUNNING)" ;;
    app.stop) echo STOPPED >"$FAKE/state-$1" ;;
    app.start) [ "$1" = "${NEVER_STARTS:-}" ] || echo RUNNING >"$FAKE/state-$1" ;;
esac
EOF
# curl: config download from 127.0.0.1, everything else (pings, notifications) is logged.
cat >"$T/bin/curl" <<'EOF'
#!/bin/bash
out=""; url="${*: -1}"; args=("$@")
for i in "${!args[@]}"; do [ "${args[$i]}" = -o ] && out="${args[$((i + 1))]}"; done
if [[ "$url" == http://127.0.0.1/_download/* ]]; then cp "$FAKE/${CONFIG_TAR:-config-good.tar}" "$out"; exit 0; fi
for a in "$@"; do [ "$a" = @- ] && url="$url $(cat)"; done
echo "curl $url" >>"$FAKE/calls"
EOF
chmod +x "$T/bin/midclt" "$T/bin/curl"
export PATH="$T/bin:$PATH"

check() {   # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; FAIL=1; fi
}
DATA="$T/data"
mkdir -p "$DATA/kuma" "$DATA/bot/cache" "$DATA/config"
echo db >"$DATA/kuma/kuma.db"; echo token >"$DATA/bot/bot.json"; echo junk >"$DATA/bot/cache/x"
echo "<?php" >"$DATA/config/config.php"

setup() {   # setup <extra settings>: fresh BACKUP_DIR and settings file
    B="$(mktemp -d)"
    export SYSTEM_BACKUP_CONF="$B/system-backup.conf"
    cat >"$SYSTEM_BACKUP_CONF" <<EOF
BACKUP_DIR="$B"
MIN_FREE_GB=0
APP_START_TIMEOUT=10
HEALTHCHECKS_URL="https://hc.example/ping/x"
NOTIFY_URL="https://ntfy.example/t"
$1
EOF
    chmod 600 "$SYSTEM_BACKUP_CONF"
    : >"$FAKE/calls"; rm -f "$FAKE"/state-*
}
backup() { bash "$SRC/system-backup/system-backup.sh" >"$B/out" 2>&1; }
verify() { bash "$SRC/system-backup/system-backup-verify.sh" >"$B/vout" 2>&1; }
calls() { grep -c -- "$1" "$FAKE/calls" || true; }

export FAKE_APPS="uptime-kuma telegram-bot nextcloud"
ARCH='ARCHIVES=(
  "monitoring|uptime-kuma,telegram-bot|'"$DATA/kuma,$DATA/bot"'|*/cache|'"$DATA/kuma/kuma.db"'"
  "live||'"$DATA/config,?$T/not-there"'||'"$DATA/config/config.php"'"
)'

# 1. A full backup.
setup "APP_CONFIGS=(\"*\")
$ARCH"
backup; check "backup: exit code" 0 $?
L="$(readlink -f "$B/latest")"
check "backup: folder renamed, latest points to it" 1 "$(find "$B" -maxdepth 1 -name '20*' -type d | wc -l)"
check "backup: no .incomplete folder left" 0 "$(find "$B" -maxdepth 1 -name '.incomplete-*' | wc -l)"
check "backup: TrueNAS configuration" 1 "$(find "$L/truenas" -name 'truenas-config-25.10.8-*.tar' | wc -l)"
check "backup: app.config of every app (\"*\")" "app-query.json nextcloud.json telegram-bot.json uptime-kuma.json" "$(find "$L/app-configs" -type f -printf '%f\n' | sort | paste -sd' ')"
check "backup: apps stopped, then started" "stop uptime-kuma,stop telegram-bot,start uptime-kuma,start telegram-bot" \
    "$(grep -oE 'app\.(stop|start) [a-z-]+' "$FAKE/calls" | sed 's/app\.//' | paste -sd, -)"
check "backup: excluded folder not archived" 0 "$(tar -tzf "$L/archives/monitoring.tar.gz" | grep -c cache || true)"
check "backup: archive paths are relative" 0 "$(tar -tzf "$L/archives/live.tar.gz" | grep -c '^/' || true)"
check "backup: optional missing path is a warning" 1 "$(grep -c 'optional path missing' "$B/out")"
check "backup: checksums" 0 "$(cd "$L" && sha256sum -c --quiet metadata/SHA256SUMS >/dev/null 2>&1; echo $?)"
check "backup: status OK with 1 warning" "OK 1" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["status"], d["warnings"])' "$B/status/last_success.json")"
check "backup: Healthchecks start and success" "1 1" "$(calls 'curl https://hc.example/ping/x/start') $(calls 'curl https://hc.example/ping/x$')"
check "backup: warnings are notified" 1 "$(calls 'curl https://ntfy.example/t')"
check "backup: permissions 700/600" "700 600" "$(stat -c %a "$L") $(stat -c %a "$L/archives/live.tar.gz")"

verify; check "verify: exit code" 0 $?
check "verify: configuration, settings and archives checked" 1 "$(grep -c 'database intact, secret seed present' "$B/vout")"
check "verify: archives" 2 "$(grep -c 'ok    archive' "$B/vout")"
printf 'X' | dd of="$L/archives/live.tar.gz" bs=1 seek=20 conv=notrunc 2>/dev/null
verify; check "verify: damaged archive, exit code 1" 1 $?
check "verify: damaged archive found" 2 "$(grep -cE 'FAIL  (checksums|archive live)' "$B/vout")"
check "verify: status file" ERROR "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$B/status/last_verify.json")"

# 2. A required file is missing: the backup fails, apps are restarted, nothing is left.
setup 'ARCHIVES=("monitoring|uptime-kuma|'"$DATA/kuma"'||'"$DATA/kuma/missing.db"'")'
backup; check "missing required file: exit code 1" 1 $?
check "missing required file: app restarted" RUNNING "$(cat "$FAKE/state-uptime-kuma")"
check "missing required file: no backup folder" 0 "$(find "$B" -maxdepth 1 \( -name '20*' -o -name '.incomplete-*' \) | wc -l)"
check "missing required file: status ERROR, Healthchecks fail, notification" "ERROR 1 1" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$B/status/last_run.json") $(calls 'ping/x/fail') $(calls 'FAILED\|ntfy.example')"

# 3. config.save without the secret seed is refused.
setup ''
CONFIG_TAR=config-noseed.tar backup; check "config without secret seed: exit code 1" 1 $?
check "config without secret seed: message" 1 "$(grep -c 'no secret seed' "$B/out")"

# 4. An app that does not come back is an error.
setup 'ARCHIVES=("m|uptime-kuma|'"$DATA/kuma"'||")
APP_START_TIMEOUT=5'
NEVER_STARTS=uptime-kuma backup; check "app not running again: exit code 1" 1 $?
check "app not running again: message" 1 "$(grep -c 'uptime-kuma is not RUNNING' "$B/out")"

# 5. Retention: daily for KEEP_DAILY days, then the first backup of each month, .keep forever.
setup 'TRUENAS_CONFIG=no
KEEP_DAILY=10
KEEP_MONTHLY=2
ARCHIVES=("live||'"$DATA/config"'||")'
python3 - "$B" <<'PY'
import sys
from datetime import datetime, timedelta
from pathlib import Path
now = datetime.now()
def mk(dt, keep=False):
    p = Path(sys.argv[1]) / dt.strftime("%Y-%m-%d_%H-%M-%S")
    p.mkdir()
    if keep:
        (p / ".keep").touch()
    (Path(sys.argv[1]) / "expected").open("a").write(p.name + "\n")
first = lambda months: (now.replace(day=1) - timedelta(days=31 * months)).replace(day=1, hour=3, minute=0, second=0, microsecond=0)
mk(now - timedelta(days=2))                                  # recent: kept
for m in (2, 3, 4):
    mk(first(m))                                             # first of month: 2 kept, 1 removed
    (Path(sys.argv[1]) / first(m).replace(day=15).strftime("%Y-%m-%d_%H-%M-%S")).mkdir()  # mid-month: removed
mk(first(14), keep=True)                                     # .keep: kept
PY
EXPECTED="$(head -n 3 "$B/expected"; tail -n 1 "$B/expected")"
rm "$B/expected"
backup; check "retention: exit code" 0 $?
check "retention: kept folders" "$(printf '%s\n' "$EXPECTED" "$(basename "$(readlink -f "$B/latest")")" | sort | paste -sd' ')" \
    "$(find "$B" -maxdepth 1 -name '20*' -type d -printf '%f\n' | sort | paste -sd' ')"

# 6. Bad settings stop before anything is written.
for bad in 'KEEP_DAILY=0' 'PG_DUMPS=("only two")' 'MYSQL_DUMPS=("db app shop" "db root shop")' 'ARCHIVES=("x|y")' 'ARCHIVES=("x||relative/path|")' 'NOTIFY_ON=sometimes'; do
    setup "$bad"; backup; rc=$?
    check "bad settings ($bad): exit code 1, nothing written" "1 0" "$rc $(find "$B" -mindepth 1 -maxdepth 1 ! -name system-backup.conf ! -name out | wc -l)"
done

# 7. One backup at a time.
setup 'TRUENAS_CONFIG=no
ARCHIVES=("live||'"$DATA/config"'||")'
flock "$B/.system-backup.lock" sleep 3 & sleep 0.5
backup; check "lock held: exit code 0, nothing done" "0 0" "$? $(find "$B" -maxdepth 1 -name '20*' | wc -l)"
wait

if [ "$FAIL" -ne 0 ]; then echo "some system-backup tests FAILED"; exit 1; fi
echo "all system-backup tests passed"
