#!/bin/bash
# ============================================================================
# system-backup.sh: EXAMPLE, NOT A DROP-IN SCRIPT
#
# The nightly backup of one specific TrueNAS homelab, published as a reference.
# It names that system's apps, containers and folders, STOPS AND RESTARTS some
# apps, and fails on purpose when something it expects is missing.
#
# Read it all before running it. To reuse it, rewrite the "Site-specific
# settings" block below, and the per-app stop/restart logic (AutoDiskCopy,
# Telegram bot, Scrutiny, Uptime Kuma), for your own system. Try it first on a
# day when a failed backup or a stopped app does not hurt.
#
# What it shows (see the README): verified config.save with the secret seed, hot
# pg_dump checked with pg_restore --list, app archives with apps stopped only
# when needed, SHA-256 checksums, a manifest, retention, and an .incomplete-*
# folder renamed only at the end. The backup contains secrets: keep it private.
# ============================================================================
set -Eeuo pipefail
umask 077

DATA_POOL="${DATA_POOL:-tank}"        # pool that holds the backups
APPS_ROOT="${APPS_ROOT:-/mnt/Apps}"   # dataset with the app folders (host paths of the custom apps)
BASE="/mnt/$DATA_POOL/SystemBackups"
TOOLS="$BASE/.tools"
LOGS="$BASE/logs"
STATUS="$BASE/status"

# ----------------------------------------------------------------------------
# Site-specific settings: everything in this block belongs to the original homelab
# ----------------------------------------------------------------------------

# Apps stopped during the archive and restarted after it (TrueNAS app names)
ADC="auto-disk-copy"
TGB="truenas-telegram-bot"
SCR="scrutiny"
KUMA="uptime-kuma"
HP="controlcenter"   # admin dashboard, never stopped: only checked to be RUNNING

# AutoDiskCopy is stopped only when idle: its API says whether it is copying
ADC_DIR="AutoDiskCopy"   # its folder under APPS_ROOT
ADC_AUTH="$APPS_ROOT/AutoDiskCopy/config/auth.json"
ADC_STATUS_URL="http://127.0.0.1:8099/api/status"
ADC_WAIT_MAX=2700   # maximum wait in seconds while AutoDiskCopy is copying

# Telegram bot whose token and chat id are reused for the result notification
TGCFG="$APPS_ROOT/TrueNASTelegramBot/config/telegram.json"

# Apps whose app.config (TrueNAS app settings) is saved
APP_CONFIGS=(
    auto-disk-copy truenas-telegram-bot scrutiny tailscale hdd-fancontrol
    controlcenter portale convertitore uptime-kuma nextcloud authentik
    gokapi tmodloader fritzbox-proxy
)

# PostgreSQL databases dumped hot, one "container user database" per entry
PG_DUMPS=(
    "ix-nextcloud-postgres-1 nextcloud nextcloud"
    "ix-authentik-postgres-1 authentik authentik"
)

# Folders under APPS_ROOT archived while their apps are stopped
# (AutoDiskCopy is added when it can be stopped)
STOPPED_DIRS=(TrueNASTelegramBot Scrutiny Homepage UptimeKuma TrueNAS-Documentation)

# Folders under APPS_ROOT archived while their apps keep running
LIVE_APPS=(
    TrueNAS-AutoUpdate TrueNAS-SelfHeal TrueNAS-SMART TrueNAS-PdfConvert
    TrueNAS-Heartbeat TrueNAS-Firewall
    FanControl FanControlApp FanControlTrueNAS
    Authentik
    Nextcloud/html/config Nextcloud/html/custom_apps Nextcloud/html/themes Nextcloud/tools
)
LIVE_EXCLUDES=('Authentik/postgres_data' '.tmod-control/updates')

# Other absolute paths archived live (skipped with a warning if missing)
EXTRA_PATHS=(
    "/mnt/$DATA_POOL/Gokapi"
    /mnt/.ix-apps/app_mounts/authentik/certs
    /mnt/.ix-apps/app_mounts/authentik/data
    /mnt/.ix-apps/app_mounts/authentik/templates
    /mnt/.ix-apps/app_mounts/tmodloader/data
)

# Files that must be in the live archive, or the backup fails
LIVE_REQUIRED=('Nextcloud/html/config/config.php' "$DATA_POOL/Gokapi/config")

# ----------------------------------------------------------------------------
# End of site-specific settings
# ----------------------------------------------------------------------------

ADC_SKIP_STOP=0
WARNINGS=""

STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
START_EPOCH="$(date +%s)"

WORK="$BASE/.incomplete-$STAMP"
FINAL="$BASE/$STAMP"
LOG="$LOGS/backup-$(date +%Y-%m).log"

ADC_WAS_RUNNING=0
TGB_WAS_RUNNING=0
SCR_WAS_RUNNING=0
KUMA_WAS_RUNNING=0
SUCCESS=0

mkdir -p "$LOGS" "$STATUS"

# Prevent two backups from running at the same time.
exec 9>"$TOOLS/system-backup.lock"

if ! flock -n 9; then
    exit 0
fi

# Simple rotation of the current log at 5 MiB.
if [ -f "$LOG" ]; then
    SIZE="$(stat -c '%s' "$LOG" 2>/dev/null || echo 0)"
    if [ "$SIZE" -gt 5242880 ]; then
        mv "$LOG" "$LOG.$(date +%Y%m%d-%H%M%S)"
    fi
fi

exec > >(tee -a "$LOG") 2>&1

log() {
    printf '[%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*"
}

warn() {
    log "WARN $*"
    WARNINGS="${WARNINGS}
- $*"
}

# tar that accepts "file changed as we read it" (rc 1) on data of running apps.
tar_live() {
    local RC=0
    tar "$@" || RC=$?
    if [ "$RC" -eq 1 ]; then
        log "WARN tar: some files changed while being read (normal for running apps)"
    elif [ "$RC" -ne 0 ]; then
        return "$RC"
    fi
}

# AutoDiskCopy state: STOPPED/IDLE..., OFF if the app does not answer (connection refused),
# UNKNOWN if the state cannot be read. Credentials go through stdin, not the command line.
adc_status() {
    local OUT="" RC=0
    [ -r "$ADC_AUTH" ] || { echo UNKNOWN; return 0; }
    OUT="$(
        printf 'user = "%s:%s"\n' \
            "$(jq -r .username "$ADC_AUTH")" "$(jq -r .password "$ADC_AUTH")" |
        curl --silent --fail --max-time 10 -K - "$ADC_STATUS_URL"
    )" || RC=$?
    if [ "$RC" -eq 7 ]; then echo OFF; return 0; fi
    if [ "$RC" -ne 0 ]; then echo UNKNOWN; return 0; fi
    echo "$OUT" | jq -r '.status // "UNKNOWN"' 2>/dev/null || echo UNKNOWN
}

adc_busy() {
    case "$(adc_status)" in
        SCANNING|COPYING|VERIFYING|STOPPING|UNKNOWN) return 0 ;;
        *) return 1 ;;
    esac
}

dump_pg() {
    local C="$1" U="$2" DB="$3"
    local OUT="$WORK/databases/${DB}.dump"
    docker exec "$C" pg_dump -U "$U" -d "$DB" -Fc > "$OUT"
    [ -s "$OUT" ]
    docker exec -i "$C" pg_restore --list < "$OUT" > /dev/null
    docker exec "$C" pg_dumpall -U "$U" --globals-only > "$WORK/databases/${DB}-globals.sql"
    chmod 600 "$OUT" "$WORK/databases/${DB}-globals.sql"
    log "pg_dump OK: $DB ($(du -h --apparent-size "$OUT" | cut -f1))"
}

telegram_notify() {
    local MESSAGE="$1"

    [ -r "$TGCFG" ] || return 0

    local TOKEN CHAT

    TOKEN="$(
        jq -r '
          .bot_token
          // .token
          // .telegram_token
          // .api_token
          // empty
        ' "$TGCFG" 2>/dev/null
    )"

    CHAT="$(
        jq -r '
          (.allowed_chat_ids // [])[0]
          // .chat_id
          // empty
        ' "$TGCFG" 2>/dev/null
    )"

    if [ -z "$TOKEN" ] || [ -z "$CHAT" ]; then
        log "Telegram: configuration not recognised, notification skipped"
        return 0
    fi

    curl \
        --fail \
        --silent \
        --show-error \
        --max-time 20 \
        --data-urlencode "chat_id=$CHAT" \
        --data-urlencode "text=$MESSAGE" \
        "https://api.telegram.org/bot${TOKEN}/sendMessage" \
        >/dev/null 2>&1 || \
        log "Telegram: sending the notification failed"
}

restore_apps() {
    set +e

    if [ "$ADC_WAS_RUNNING" -eq 1 ]; then
        STATE="$(
            midclt call app.get_instance "$ADC" 2>/dev/null |
            jq -r '.state' 2>/dev/null
        )"

        if [ "$STATE" != "RUNNING" ]; then
            log "Restarting AutoDiskCopy"
            midclt call -j app.start "$ADC" >/dev/null 2>&1
        fi
    fi

    if [ "$TGB_WAS_RUNNING" -eq 1 ]; then
        STATE="$(
            midclt call app.get_instance "$TGB" 2>/dev/null |
            jq -r '.state' 2>/dev/null
        )"

        if [ "$STATE" != "RUNNING" ]; then
            log "Restarting Telegram Bot"
            midclt call -j app.start "$TGB" >/dev/null 2>&1
        fi
    fi

    if [ "$SCR_WAS_RUNNING" -eq 1 ]; then
        STATE="$(
            midclt call app.get_instance "$SCR" 2>/dev/null |
            jq -r '.state' 2>/dev/null
        )"

        if [ "$STATE" != "RUNNING" ]; then
            log "Restarting Scrutiny"
            midclt call -j app.start "$SCR" >/dev/null 2>&1
        fi
    fi

    if [ "$KUMA_WAS_RUNNING" -eq 1 ]; then
        STATE="$(
            midclt call app.get_instance "$KUMA" 2>/dev/null |
            jq -r '.state' 2>/dev/null
        )"

        if [ "$STATE" != "RUNNING" ]; then
            log "Restarting Uptime Kuma"
            midclt call -j app.start "$KUMA" >/dev/null 2>&1
        fi
    fi

}

# shellcheck disable=SC2329  # called by the trap below
finish() {
    RC=$?

    restore_apps

    if [ "$SUCCESS" -eq 0 ]; then
        rm -rf "$WORK" 2>/dev/null || true

        jq -nc \
            --arg status "ERROR" \
            --arg timestamp "$STAMP" \
            --arg log "$LOG" \
            --argjson exit_code "$RC" \
            '{
              status:$status,
              timestamp:$timestamp,
              exit_code:$exit_code,
              log:$log
            }' \
            > "$STATUS/last_run.json"

        chmod 600 "$STATUS/last_run.json"

        telegram_notify \
"🚨 TrueNAS backup FAILED
Date: $STAMP
Check:
$LOG"
    fi

    exit "$RC"
}

trap finish EXIT INT TERM

log "============================================================"
log "TRUENAS BACKUP STARTED"
log "============================================================"

# ------------------------------------------------------------
# Free space check
# ------------------------------------------------------------

AVAILABLE="$(
    zfs get -Hp -o value available "$DATA_POOL/SystemBackups"
)"

if [ "$AVAILABLE" -lt 5368709120 ]; then
    log "ERROR: less than 5 GiB available"
    exit 1
fi

mkdir -p \
    "$WORK/truenas" \
    "$WORK/custom-apps" \
    "$WORK/app-configs" \
    "$WORK/databases" \
    "$WORK/metadata"

chmod 700 "$WORK" "$WORK"/*

# ------------------------------------------------------------
# TrueNAS configuration + secret seed
# ------------------------------------------------------------

log "Backing up the TrueNAS configuration"

VERSION="$(midclt call system.version | tr -d '"')"

CFGNAME="truenas-config-${VERSION}-${STAMP}.tar"
CFG="$WORK/truenas/$CFGNAME"

DOWNLOAD="$(
    midclt call core.download \
        "config.save" \
        '[{"secretseed":true,"root_authorized_keys":false}]' \
        "$CFGNAME"
)"

JOB_ID="$(echo "$DOWNLOAD" | jq -r '.[0]')"
DOWNLOAD_PATH="$(echo "$DOWNLOAD" | jq -r '.[1]')"

[ -n "$DOWNLOAD_PATH" ] &&
[ "$DOWNLOAD_PATH" != "null" ] || {
    log "ERROR: core.download did not return the file"
    exit 1
}

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --insecure \
    --output "$CFG" \
    "http://127.0.0.1${DOWNLOAD_PATH}"

chmod 600 "$CFG"

[ -s "$CFG" ]
tar -tf "$CFG" >/dev/null
tar -tf "$CFG" | grep -q 'freenas-v1.db'
tar -tf "$CFG" | grep -q 'pwenc_secret'

log "TrueNAS configuration OK - job $JOB_ID"

# ------------------------------------------------------------
# App configurations (API)
# ------------------------------------------------------------

log "Saving app configurations"

midclt call app.query \
    > "$WORK/app-configs/app-query.json"

for APP in "${APP_CONFIGS[@]}"
do
    if midclt call app.config "$APP" \
        > "$WORK/app-configs/${APP}.json" 2>/dev/null
    then
        jq empty "$WORK/app-configs/${APP}.json"
        log "app.config OK: $APP"
    else
        rm -f "$WORK/app-configs/${APP}.json"
        log "WARN app.config not available: $APP"
    fi
done

chmod 600 "$WORK/app-configs/"*

# ------------------------------------------------------------
# Databases (hot dump, consistent: pg_dump runs in a single transaction)
# ------------------------------------------------------------

log "Dumping PostgreSQL databases"

for D in "${PG_DUMPS[@]}"; do
    read -r C U DB <<< "$D"
    dump_pg "$C" "$U" "$DB"
done

# ------------------------------------------------------------
# Custom app state
# ------------------------------------------------------------

ADC_STATE="$(
    midclt call app.get_instance "$ADC" |
    jq -r '.state'
)"

TGB_STATE="$(
    midclt call app.get_instance "$TGB" |
    jq -r '.state'
)"

SCR_STATE="$(
    midclt call app.get_instance "$SCR" |
    jq -r '.state'
)"

[ "$ADC_STATE" = "RUNNING" ] &&
    ADC_WAS_RUNNING=1

[ "$TGB_STATE" = "RUNNING" ] &&
    TGB_WAS_RUNNING=1

[ "$SCR_STATE" = "RUNNING" ] &&
    SCR_WAS_RUNNING=1

KUMA_STATE="$(
    midclt call app.get_instance "$KUMA" 2>/dev/null |
    jq -r '.state' 2>/dev/null ||
    true
)"

[ "$KUMA_STATE" = "RUNNING" ] &&
    KUMA_WAS_RUNNING=1

# ------------------------------------------------------------
# Temporary stop
# ------------------------------------------------------------

if [ "$ADC_WAS_RUNNING" -eq 1 ] && adc_busy; then
    log "AutoDiskCopy busy ($(adc_status)): waiting up to $((ADC_WAIT_MAX / 60)) minutes"
    WAITED=0
    while adc_busy && [ "$WAITED" -lt "$ADC_WAIT_MAX" ]; do
        sleep 60
        WAITED=$((WAITED + 60))
    done
    if adc_busy; then
        ADC_SKIP_STOP=1
        ADC_WAS_RUNNING=0
        warn "AutoDiskCopy still busy after $((WAITED / 60)) min ($(adc_status)): not stopped, backed up live"
    else
        log "AutoDiskCopy idle after $((WAITED / 60)) min"
    fi
fi

if [ "$ADC_WAS_RUNNING" -eq 1 ]; then
    log "Temporarily stopping AutoDiskCopy"
    midclt call -j app.stop "$ADC" >/dev/null
fi

if [ "$TGB_WAS_RUNNING" -eq 1 ]; then
    log "Temporarily stopping Telegram Bot"
    midclt call -j app.stop "$TGB" >/dev/null
fi

if [ "$SCR_WAS_RUNNING" -eq 1 ]; then
    log "Temporarily stopping Scrutiny"
    midclt call -j app.stop "$SCR" >/dev/null
fi

if [ "$KUMA_WAS_RUNNING" -eq 1 ]; then
    log "Temporarily stopping Uptime Kuma"
    midclt call -j app.stop "$KUMA" >/dev/null
fi

# ------------------------------------------------------------
# Custom app archive
# ------------------------------------------------------------

log "Creating the custom app archive"

APPARCH="$WORK/custom-apps/custom-apps-${STAMP}.tar.gz"

[ "$ADC_SKIP_STOP" -eq 0 ] && STOPPED_DIRS=("$ADC_DIR" "${STOPPED_DIRS[@]}")

tar \
    --acls \
    --xattrs \
    -czf "$APPARCH" \
    -C "$APPS_ROOT" \
    "${STOPPED_DIRS[@]}"

chmod 600 "$APPARCH"

tar -tzf "$APPARCH" >/dev/null

# ------------------------------------------------------------
# Restart apps
# ------------------------------------------------------------

restore_apps

ADC_WAS_RUNNING=0
TGB_WAS_RUNNING=0
SCR_WAS_RUNNING=0
KUMA_WAS_RUNNING=0

sleep 8

for APP in "$ADC" "$TGB" "$SCR" "$KUMA" "$HP"
do
    STATE="$(
        midclt call app.get_instance "$APP" |
        jq -r '.state'
    )"

    [ "$STATE" = "RUNNING" ] || {
        log "ERROR: $APP is not RUNNING"
        exit 1
    }
done

log "Custom apps RUNNING again"

# ------------------------------------------------------------
# Running app archive (backed up live, without stopping them)
# ------------------------------------------------------------

log "Creating the running app archive"

LIVEARCH="$WORK/custom-apps/live-apps-${STAMP}.tar.gz"

[ "$ADC_SKIP_STOP" -eq 1 ] && LIVE_APPS+=("$ADC_DIR")

EXTRA=()
for P in "${EXTRA_PATHS[@]}"
do
    if [ -e "$P" ]; then EXTRA+=("$P"); else warn "missing path, skipped: $P"; fi
done

EXCLUDE_ARGS=()
for X in "${LIVE_EXCLUDES[@]}"; do EXCLUDE_ARGS+=("--exclude=$X"); done

tar_live \
    --acls \
    --xattrs \
    "${EXCLUDE_ARGS[@]}" \
    -czf "$LIVEARCH" \
    -C "$APPS_ROOT" "${LIVE_APPS[@]}" \
    "${EXTRA[@]}"

chmod 600 "$LIVEARCH"

LIVELIST="$(tar -tzf "$LIVEARCH")"
for F in "${LIVE_REQUIRED[@]}"; do
    grep -qF "$F" <<< "$LIVELIST" || {
        log "ERROR: $F is missing from the running app archive"
        exit 1
    }
done

log "Running app archive OK ($(du -h --apparent-size "$LIVEARCH" | cut -f1))"

# ------------------------------------------------------------
# Manifest
# ------------------------------------------------------------

cat > "$WORK/metadata/manifest.txt" <<EOF
TrueNAS System Backup

Timestamp: $STAMP
Version: $VERSION
config.save job: $JOB_ID

Contents:
- TrueNAS configuration, with the password secret seed
- app.config of: ${APP_CONFIGS[*]}
- PostgreSQL databases (pg_dump -Fc, restore with pg_restore): $(for D in "${PG_DUMPS[@]}"; do read -r _ _ DB <<< "$D"; printf '%s ' "$DB"; done)
- folders of $APPS_ROOT archived with their apps stopped: ${STOPPED_DIRS[*]}
- folders of $APPS_ROOT archived live: ${LIVE_APPS[*]}
- other paths archived live: ${EXTRA[*]:-none}

Automatic retention:
- daily: 30 days
- monthly: 12
- folders containing .keep: kept forever

WARNING:
this backup contains sensitive information.
EOF

chmod 600 "$WORK/metadata/manifest.txt"

# ------------------------------------------------------------
# Checksums
# ------------------------------------------------------------

log "Computing checksums"

(
    cd "$WORK"

    find . \
        -type f \
        ! -path './metadata/SHA256SUMS' \
        -print0 |
    sort -z |
    xargs -0 sha256sum \
        > metadata/SHA256SUMS

    sha256sum -c metadata/SHA256SUMS >/dev/null
)

chmod 600 "$WORK/metadata/SHA256SUMS"

# ------------------------------------------------------------
# Atomic publish
# ------------------------------------------------------------

mv "$WORK" "$FINAL"
chmod 700 "$FINAL"

ln -sfn "$FINAL" "$BASE/latest"

# ------------------------------------------------------------
# Retention
# ------------------------------------------------------------

log "Applying retention"

python3 - "$BASE" "$FINAL" <<'PY'
from pathlib import Path
from datetime import datetime, timedelta
import re
import shutil
import sys

base = Path(sys.argv[1])
current = Path(sys.argv[2]).resolve()

pattern = re.compile(
    r"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"
)

entries = []

for p in base.iterdir():
    if not p.is_dir():
        continue

    if not pattern.match(p.name):
        continue

    try:
        dt = datetime.strptime(
            p.name,
            "%Y-%m-%d_%H-%M-%S"
        )
    except ValueError:
        continue

    entries.append((p, dt))

now = datetime.now()
daily_cutoff = now - timedelta(days=30)

older_monthlies = sorted(
    [
        (p, dt)
        for p, dt in entries
        if dt < daily_cutoff
        and dt.day == 1
        and not (p / ".keep").exists()
    ],
    key=lambda x: x[1],
    reverse=True
)

monthly_keep = {
    p.resolve()
    for p, _ in older_monthlies[:12]
}

for p, dt in entries:
    rp = p.resolve()

    if rp == current:
        continue

    if (p / ".keep").exists():
        continue

    if dt >= daily_cutoff:
        continue

    if rp in monthly_keep:
        continue

    shutil.rmtree(p)
    print(f"Removed by retention: {p.name}")
PY

# ------------------------------------------------------------
# Machine-readable status
# ------------------------------------------------------------

END_EPOCH="$(date +%s)"
DURATION="$((END_EPOCH - START_EPOCH))"

SIZE_BYTES="$(
    du -sb "$FINAL" |
    awk '{print $1}'
)"

jq -nc \
    --arg status "OK" \
    --arg timestamp "$STAMP" \
    --arg path "$FINAL" \
    --arg version "$VERSION" \
    --argjson size_bytes "$SIZE_BYTES" \
    --argjson duration_seconds "$DURATION" \
    '{
      status:$status,
      timestamp:$timestamp,
      path:$path,
      version:$version,
      size_bytes:$size_bytes,
      duration_seconds:$duration_seconds
    }' \
    > "$STATUS/last_run.json"

cp "$STATUS/last_run.json" \
   "$STATUS/last_success.json"

chmod 600 \
    "$STATUS/last_run.json" \
    "$STATUS/last_success.json"

SUCCESS=1

SIZE_HUMAN="$(du -sh "$FINAL" | awk '{print $1}')"

log "Backup completed: $FINAL"
log "Size: $SIZE_HUMAN"
log "Duration: ${DURATION}s"

telegram_notify \
"✅ TrueNAS backup completed
Date: $STAMP
Size: $SIZE_HUMAN
Duration: ${DURATION}s
Retention: 30 daily + 12 monthly${WARNINGS:+
⚠️ Warnings:$WARNINGS}"

log "============================================================"
log "BACKUP COMPLETED SUCCESSFULLY"
log "============================================================"

exit 0
