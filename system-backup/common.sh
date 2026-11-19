# shellcheck shell=bash disable=SC2034  # settings are used by the scripts that source this file
# Shared by system-backup.sh and system-backup-verify.sh: settings, logging,
# notifications. Not meant to be run on its own.

SB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
CONF="${SYSTEM_BACKUP_CONF:-$SB_DIR/system-backup.conf}"

# Defaults (see system-backup.conf.example)
BACKUP_DIR=""
MIN_FREE_GB=5
KEEP_DAILY=30
KEEP_MONTHLY=12
TRUENAS_CONFIG="yes"
APP_CONFIGS=()
PG_DUMPS=()
MYSQL_DUMPS=()
ARCHIVES=()
APP_START_TIMEOUT=300
HEALTHCHECKS_URL=""
NOTIFY_URL=""
NOTIFY_FORMAT="ntfy"
NOTIFY_TOKEN=""
NOTIFY_ON="failure"
PG_IMAGE="postgres:18-alpine"
MYSQL_IMAGE="mariadb:11"

fail() { echo "system-backup: $*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

source_secret() {   # source a settings file, warning if other users can read it
    if [ -n "$(find "$1" -perm /044 2>/dev/null)" ]; then
        echo "system-backup: $1 is readable by other users, run: chmod 600 $1" >&2
    fi
    # shellcheck source=/dev/null
    . "$1"
}

load_conf() {
    [ -f "$CONF" ] || fail "settings file $CONF not found (see system-backup.conf.example)"
    if [ -t 2 ] && [ -r /etc/version ] && [[ "$(cat /etc/version)" != 25.10* ]]; then
        echo "system-backup: TrueNAS $(cat /etc/version) has not been tested (tested: 25.10)" >&2
    fi
    # Shared settings (toolkit.conf in the toolkit folder): an empty NOTIFY_URL in
    # system-backup.conf means "use the shared notification settings".
    local tk="${TOOLKIT_CONF:-$SB_DIR/../toolkit.conf}" tk_notify=("" "" "")
    if [ -f "$tk" ]; then
        source_secret "$tk"
        tk_notify=("$NOTIFY_URL" "$NOTIFY_FORMAT" "$NOTIFY_TOKEN")
        NOTIFY_URL="" NOTIFY_FORMAT="ntfy" NOTIFY_TOKEN=""
    fi
    source_secret "$CONF"
    if [ -z "$NOTIFY_URL" ] && [ -n "${tk_notify[0]}" ]; then
        NOTIFY_URL="${tk_notify[0]}" NOTIFY_FORMAT="${tk_notify[1]:-ntfy}" NOTIFY_TOKEN="${tk_notify[2]}"
    fi
    [[ "$BACKUP_DIR" == /* && -d "$BACKUP_DIR" ]] || fail "BACKUP_DIR must be an existing absolute folder (now: '$BACKUP_DIR')"
    BACKUP_DIR="${BACKUP_DIR%/}"
    local n
    for n in MIN_FREE_GB KEEP_DAILY KEEP_MONTHLY APP_START_TIMEOUT; do
        [[ "${!n}" =~ ^[0-9]+$ ]] || fail "$n must be a whole number"
    done
    [ "$KEEP_DAILY" -ge 1 ] || fail "KEEP_DAILY must be at least 1"
    case "$TRUENAS_CONFIG" in yes|no) ;; *) fail "TRUENAS_CONFIG must be yes or no" ;; esac
    case "$NOTIFY_FORMAT" in ntfy|json) ;; *) fail "NOTIFY_FORMAT must be ntfy or json" ;; esac
    case "$NOTIFY_ON" in failure|always) ;; *) fail "NOTIFY_ON must be failure or always" ;; esac
    local e kind c u db extra seen=" "
    for e in ${PG_DUMPS[@]+"${PG_DUMPS[@]/#/pg }"} ${MYSQL_DUMPS[@]+"${MYSQL_DUMPS[@]/#/my }"}; do
        read -r kind c u db extra <<<"$e"
        [[ -n "$db" && -z "$extra" && "$c$u$db" =~ ^[A-Za-z0-9._-]+$ ]] \
            || fail "invalid database entry '${e#* }': use \"CONTAINER USER DATABASE\""
        [[ "$seen" != *" $kind/$c/$db "* ]] || fail "database $db in $c is listed twice"
        seen+="$kind/$c/$db "
    done
    local name apps paths excl req
    for e in ${ARCHIVES[@]+"${ARCHIVES[@]}"}; do
        IFS="|" read -r name apps paths _ <<<"$e"
        [[ "$e" == *"|"*"|"* && "$name" =~ ^[A-Za-z0-9._-]+$ && -n "$paths" ]] \
            || fail "invalid ARCHIVES entry '$e': use \"NAME|APPS_TO_STOP|PATHS|EXCLUDES|REQUIRED\""
        local p
        IFS=',' read -ra list <<<"$paths"
        for p in "${list[@]}"; do
            [[ "${p#\?}" == /* ]] || fail "archive '$name': paths must be absolute ('$p')"
        done
    done
}

uses_truenas() {
    [ "$TRUENAS_CONFIG" = yes ] || [ "${#APP_CONFIGS[@]}" -gt 0 ] && return 0
    local e apps
    for e in ${ARCHIVES[@]+"${ARCHIVES[@]}"}; do
        IFS='|' read -r _ apps _ <<<"$e"
        [ -n "$apps" ] && return 0
    done
    return 1
}

# Healthchecks-style ping: "" (success), "start" or "fail". Never fatal.
hc_ping() {
    [ -n "$HEALTHCHECKS_URL" ] || return 0
    curl -fsS -m 10 --retry 3 -o /dev/null "${HEALTHCHECKS_URL%/}${1:+/$1}" \
        || echo "system-backup: Healthchecks ping ${1:-success} failed" >&2
}

# notify <ok|error> <title> <message>: ntfy or JSON webhook. Never fatal.
notify() {
    [ -n "$NOTIFY_URL" ] || return 0
    local auth=() host
    host="$(hostname)"
    [ -n "$NOTIFY_TOKEN" ] && auth=(-H "Authorization: Bearer $NOTIFY_TOKEN")
    if [ "$NOTIFY_FORMAT" = json ]; then
        python3 -c 'import json,sys,time; print(json.dumps({"host": sys.argv[1], "status": sys.argv[2], "title": sys.argv[3], "msg": sys.argv[4], "time": int(time.time())}))' \
            "$host" "$1" "$2" "$3" \
            | curl -fsS -m 20 -o /dev/null ${auth[@]+"${auth[@]}"} -H "Content-Type: application/json" --data-binary @- "$NOTIFY_URL"
    else
        curl -fsS -m 20 -o /dev/null ${auth[@]+"${auth[@]}"} -H "Title: $host: $2" \
            -H "Tags: $([ "$1" = ok ] && echo white_check_mark || echo rotating_light)" \
            -H "Priority: $([ "$1" = ok ] && echo default || echo high)" \
            --data-binary "$3" "$NOTIFY_URL"
    fi || echo "system-backup: notification failed" >&2
}

# Write a small JSON status file: write_status <file> key=value... (values are strings
# unless they look like integers).
write_status() {
    local file="$1"; shift
    python3 - "$@" >"$file.tmp" <<'PY'
import json, sys
d = {}
for kv in sys.argv[1:]:
    k, _, v = kv.partition("=")
    d[k] = int(v) if v.lstrip("-").isdigit() else v
print(json.dumps(d))
PY
    chmod 600 "$file.tmp"
    mv "$file.tmp" "$file"
}
