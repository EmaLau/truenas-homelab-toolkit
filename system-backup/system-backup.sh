#!/bin/bash
# system-backup: nightly backup of a TrueNAS system, driven by system-backup.conf
# (see system-backup.conf.example). Run as root from cron.
#
# Each backup is a folder BACKUP_DIR/YYYY-MM-DD_HH-MM-SS with:
#   truenas/      config.save with the secret seed, verified
#   app-configs/  app.query and the app.config of the chosen apps
#   databases/    pg_dump -Fc (checked with pg_restore --list) and
#                 mariadb-dump/mysqldump (checked for its end marker)
#   archives/     one tar.gz per ARCHIVES entry, apps stopped only for their own archive
#   metadata/     manifest.json and SHA256SUMS
# Work happens in .incomplete-*, renamed only at the end; stopped apps are
# restarted even when the backup fails. Check a backup with system-backup-verify.sh.
# The backup contains secrets: keep BACKUP_DIR private.
set -Eeuo pipefail
umask 077
# shellcheck source=system-backup/common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
load_conf
if uses_truenas; then
    command -v midclt >/dev/null || fail "midclt not found: TRUENAS_CONFIG, APP_CONFIGS and apps to stop need TrueNAS"
fi

mkdir -p "$BACKUP_DIR/logs" "$BACKUP_DIR/status"
exec 9>"$BACKUP_DIR/.system-backup.lock"
flock -n 9 || { echo "system-backup: another backup is running" >&2; exit 0; }

STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
START="$(date +%s)"
WORK="$BACKUP_DIR/.incomplete-$STAMP"
FINAL="$BACKUP_DIR/$STAMP"
LOG="$BACKUP_DIR/logs/backup-$(date +%Y-%m).log"
exec > >(tee -a "$LOG") 2>&1

STOPPED=()     # apps stopped by this run and not restarted yet
WARNINGS=()
SUCCESS=0
warn() { log "WARN $*"; WARNINGS+=("$*"); }

app_state() { midclt call app.get_instance "$1" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null || true; }

start_apps() {
    local app t rc=0
    for app in ${STOPPED[@]+"${STOPPED[@]}"}; do
        log "Starting $app"
        midclt call -j app.start "$app" >/dev/null 2>&1 || true
    done
    for app in ${STOPPED[@]+"${STOPPED[@]}"}; do
        t=0
        while [ "$(app_state "$app")" != RUNNING ] && [ "$t" -lt "$APP_START_TIMEOUT" ]; do sleep 5; t=$((t + 5)); done
        if [ "$(app_state "$app")" = RUNNING ]; then log "$app is RUNNING"; else log "ERROR: $app is not RUNNING after ${APP_START_TIMEOUT}s"; rc=1; fi
    done
    STOPPED=()
    return "$rc"
}

# shellcheck disable=SC2329  # called by the trap
finish() {
    local rc=$?
    set +e
    start_apps || rc=1
    if [ "$SUCCESS" -ne 1 ]; then
        [ "$rc" -eq 0 ] && rc=1
        rm -rf "$WORK"
        write_status "$BACKUP_DIR/status/last_run.json" status=ERROR timestamp="$STAMP" exit_code="$rc" log="$LOG"
        log "BACKUP FAILED (exit code $rc), see $LOG"
        hc_ping fail
        notify error "backup FAILED" "Backup $STAMP failed (exit code $rc). Log: $LOG"
    fi
    exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT TERM

log "==== system-backup $STAMP ===="
hc_ping start

AVAIL_KB="$(df -Pk "$BACKUP_DIR" | awk 'NR==2 {print $4}')"
if [ "$AVAIL_KB" -lt $((MIN_FREE_GB * 1024 * 1024)) ]; then
    log "ERROR: less than $MIN_FREE_GB GiB free in $BACKUP_DIR"
    exit 1
fi
mkdir -p "$WORK"/{truenas,app-configs,databases,archives,metadata}

# --- TrueNAS configuration with the secret seed ---------------------------
VERSION=""
if [ "$TRUENAS_CONFIG" = yes ]; then
    VERSION="$(midclt call system.version | tr -d '"')"
    CFG="$WORK/truenas/truenas-config-$VERSION-$STAMP.tar"
    DL="$(midclt call core.download config.save '[{"secretseed":true,"root_authorized_keys":false}]' "$(basename "$CFG")")"
    DL_PATH="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[1])' "$DL")"
    curl -fsS -m 300 --location --insecure -o "$CFG" "http://127.0.0.1$DL_PATH"   # local only
    tar -tf "$CFG" >"$WORK/truenas/.list"
    grep -q 'freenas-v1.db' "$WORK/truenas/.list" || { log "ERROR: config.save has no database"; exit 1; }
    grep -q 'pwenc_secret' "$WORK/truenas/.list" || { log "ERROR: config.save has no secret seed"; exit 1; }
    rm -f "$WORK/truenas/.list"
    log "TrueNAS configuration OK (version $VERSION)"
fi

# --- App settings ----------------------------------------------------------
if [ "${#APP_CONFIGS[@]}" -gt 0 ]; then
    midclt call app.query >"$WORK/app-configs/app-query.json"
    if [ "${APP_CONFIGS[*]}" = "*" ]; then
        mapfile -t APP_CONFIGS < <(python3 -c 'import json,sys; [print(a["name"]) for a in json.load(open(sys.argv[1]))]' "$WORK/app-configs/app-query.json")
    fi
    for APP in "${APP_CONFIGS[@]}"; do
        if midclt call app.config "$APP" >"$WORK/app-configs/$APP.json" 2>/dev/null \
            && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$WORK/app-configs/$APP.json"; then
            log "app.config OK: $APP"
        else
            rm -f "$WORK/app-configs/$APP.json"
            warn "app.config not available: $APP"
        fi
    done
fi

# --- Databases (hot dumps, each in one transaction) --------------------------
for E in ${PG_DUMPS[@]+"${PG_DUMPS[@]}"}; do
    read -r C U DB <<<"$E"
    OUT="$WORK/databases/pg-$C-$DB.dump"
    docker exec "$C" pg_dump -U "$U" -d "$DB" -Fc >"$OUT"
    [ "$(head -c 5 "$OUT")" = PGDMP ] || { log "ERROR: $DB: not a pg_dump archive"; exit 1; }
    docker exec -i "$C" pg_restore --list <"$OUT" >/dev/null
    docker exec "$C" pg_dumpall -U "$U" --globals-only >"$WORK/databases/pg-$C-globals.sql"
    log "PostgreSQL OK: $DB in $C ($(du -h --apparent-size "$OUT" | cut -f1))"
done
for E in ${MYSQL_DUMPS[@]+"${MYSQL_DUMPS[@]}"}; do
    read -r C U DB <<<"$E"
    OUT="$WORK/databases/mysql-$C-$DB.sql.gz"
    # The password comes from the container's own environment, never from this host's command line.
    # shellcheck disable=SC2016  # expanded inside the container
    docker exec "$C" sh -c '
        if [ "$1" = root ]; then p="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
        else p="${MARIADB_PASSWORD:-${MYSQL_PASSWORD:-}}"; fi
        dump="$(command -v mariadb-dump || command -v mysqldump)"
        MYSQL_PWD="$p" exec "$dump" --single-transaction --routines --triggers --events -u "$1" "$2"' \
        sh "$U" "$DB" | gzip >"$OUT"
    zcat "$OUT" | tail -n 1 | grep -q '^-- Dump completed' || { log "ERROR: $DB: dump incomplete"; exit 1; }
    log "MariaDB/MySQL OK: $DB in $C ($(du -h --apparent-size "$OUT" | cut -f1))"
done

# --- Archives ----------------------------------------------------------------
ARCHIVE_NAMES=()
for E in ${ARCHIVES[@]+"${ARCHIVES[@]}"}; do
    IFS='|' read -r NAME APPS PATHS EXCL REQ <<<"$E"
    IFS=',' read -ra APPS_L <<<"$APPS"
    IFS=',' read -ra PATHS_L <<<"$PATHS"
    IFS=',' read -ra EXCL_L <<<"$EXCL"
    IFS=',' read -ra REQ_L <<<"$REQ"
    MEMBERS=()
    for P in "${PATHS_L[@]}"; do
        Q="${P#\?}"
        if [ -e "$Q" ]; then MEMBERS+=("${Q#/}")
        elif [[ "$P" == \?* ]]; then warn "archive $NAME: optional path missing, skipped: ${P#\?}"
        else log "ERROR: archive $NAME: path missing: $P"; exit 1; fi
    done
    [ "${#MEMBERS[@]}" -gt 0 ] || { warn "archive $NAME: nothing to archive"; continue; }
    for APP in ${APPS_L[@]+"${APPS_L[@]}"}; do
        if [ "$(app_state "$APP")" = RUNNING ]; then
            log "Stopping $APP"
            STOPPED+=("$APP")
            midclt call -j app.stop "$APP" >/dev/null
        fi
    done
    OUT="$WORK/archives/$NAME.tar.gz"
    X=(); for P in ${EXCL_L[@]+"${EXCL_L[@]}"}; do X+=("--exclude=$P"); done
    RC=0
    tar --acls --xattrs ${X[@]+"${X[@]}"} -czf "$OUT" -C / "${MEMBERS[@]}" || RC=$?
    # rc 1 = files changed while read: normal for a live archive, an error otherwise.
    if [ "$RC" -eq 1 ] && [ "${#APPS_L[@]}" -eq 0 ]; then warn "archive $NAME: some files changed while being read (live archive)"
    elif [ "$RC" -ne 0 ]; then log "ERROR: archive $NAME: tar failed ($RC)"; exit 1; fi
    start_apps || exit 1
    tar -tzf "$OUT" >"$OUT.list"
    for R in ${REQ_L[@]+"${REQ_L[@]}"}; do
        grep -qF -- "${R#/}" "$OUT.list" || { log "ERROR: archive $NAME: required file missing: $R"; exit 1; }
    done
    rm -f "$OUT.list"
    ARCHIVE_NAMES+=("$NAME")
    log "Archive OK: $NAME ($(du -h --apparent-size "$OUT" | cut -f1))"
done

# --- Manifest and checksums --------------------------------------------------
python3 - "$WORK/metadata/manifest.json" "$STAMP" "$VERSION" "$KEEP_DAILY" "$KEEP_MONTHLY" "$WORK" <<'PY'
import json, os, sys
out, stamp, version, daily, monthly, work = sys.argv[1:]
files = sorted(os.path.relpath(os.path.join(d, f), work) for d, _, fs in os.walk(work) for f in fs)
json.dump({"timestamp": stamp, "truenas_version": version or None,
           "retention": {"daily_days": int(daily), "monthly": int(monthly)},
           "files": [f for f in files if not f.startswith("metadata/")]}, open(out, "w"), indent=1)
PY
(cd "$WORK" && find . -type f ! -path ./metadata/SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >metadata/SHA256SUMS \
    && sha256sum -c --quiet metadata/SHA256SUMS)
chmod -R go-rwx "$WORK"

mv "$WORK" "$FINAL"
ln -sfn "$FINAL" "$BACKUP_DIR/latest"

# --- Retention: KEEP_DAILY days, then the first backup of each of the last
# KEEP_MONTHLY months; folders containing .keep are never removed. -----------
python3 - "$BACKUP_DIR" "$FINAL" "$KEEP_DAILY" "$KEEP_MONTHLY" <<'PY'
import re, shutil, sys
from datetime import datetime, timedelta
from pathlib import Path
base, current, daily, monthly = Path(sys.argv[1]), Path(sys.argv[2]).resolve(), int(sys.argv[3]), int(sys.argv[4])
entries = []
for p in base.iterdir():
    if p.is_dir() and not p.is_symlink() and re.fullmatch(r"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}", p.name):
        entries.append((datetime.strptime(p.name, "%Y-%m-%d_%H-%M-%S"), p))
cutoff = datetime.now() - timedelta(days=daily)
first_of_month = {}
for dt, p in sorted(entries):
    if dt < cutoff:
        first_of_month.setdefault((dt.year, dt.month), p)
keep_monthly = {p for _, p in sorted(first_of_month.items(), reverse=True)[:monthly]}
for dt, p in entries:
    if p.resolve() == current or (p / ".keep").exists() or dt >= cutoff or p in keep_monthly:
        continue
    shutil.rmtree(p)
    print(f"Removed by retention: {p.name}")
PY

SIZE="$(du -sb "$FINAL" | cut -f1)"
DURATION=$(( $(date +%s) - START ))
write_status "$BACKUP_DIR/status/last_run.json" status=OK timestamp="$STAMP" path="$FINAL" \
    truenas_version="$VERSION" size_bytes="$SIZE" duration_seconds="$DURATION" warnings="${#WARNINGS[@]}"
cp "$BACKUP_DIR/status/last_run.json" "$BACKUP_DIR/status/last_success.json"
SUCCESS=1
log "Backup completed: $FINAL ($(du -sh "$FINAL" | cut -f1), ${DURATION}s, ${#WARNINGS[@]} warnings)"
hc_ping ""
if [ "$NOTIFY_ON" = always ] || [ "${#WARNINGS[@]}" -gt 0 ]; then
    MSG="Backup $STAMP completed: $(du -sh "$FINAL" | cut -f1) in ${DURATION}s."
    [ "${#WARNINGS[@]}" -gt 0 ] && MSG="$MSG Warnings: $(printf '%s; ' "${WARNINGS[@]}")"
    notify ok "backup completed" "$MSG"
fi
