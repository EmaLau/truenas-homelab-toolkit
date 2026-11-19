#!/bin/bash
# system-backup-verify: check that a backup made by system-backup.sh can be restored.
#
#   system-backup-verify.sh [--restore] [BACKUP_FOLDER]    (default: BACKUP_DIR/latest)
#
# Always: checksums, manifest, the TrueNAS configuration (database integrity and
# secret seed), every app setting, every archive read to the end, every dump's
# format. With --restore, each database dump is also restored into a throwaway
# container (PG_IMAGE, MYSQL_IMAGE, no network) and its tables are counted.
# Nothing outside a temporary folder is changed. Exit status 1 if anything fails.
set -Euo pipefail
umask 077
# shellcheck source=system-backup/common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"

RESTORE=no
[ "${1:-}" = --restore ] && { RESTORE=yes; shift; }
load_conf
B="$(readlink -f "${1:-$BACKUP_DIR/latest}")"
[ -f "$B/metadata/SHA256SUMS" ] || fail "$B is not a backup folder (no metadata/SHA256SUMS)"

TMP="$(mktemp -d "$BACKUP_DIR/.verify-XXXXXX")"
CONTAINERS=()
# shellcheck disable=SC2329  # called by the trap
cleanup() {
    local c
    for c in ${CONTAINERS[@]+"${CONTAINERS[@]}"}; do docker rm -f "$c" >/dev/null 2>&1; done
    rm -rf "$TMP"
}
trap cleanup EXIT

ERRORS=0
ok() { log "ok    $*"; }
bad() { log "FAIL  $*"; ERRORS=$((ERRORS + 1)); }
log "Verifying $B"

if (cd "$B" && sha256sum -c --quiet metadata/SHA256SUMS); then
    ok "checksums ($(wc -l <"$B/metadata/SHA256SUMS") files)"
else
    bad "checksums"
fi
if python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["timestamp"] and isinstance(m["files"], list)' "$B/metadata/manifest.json" 2>/dev/null; then
    ok "manifest"
else
    bad "manifest missing or unreadable"
fi

# TrueNAS configuration: the database must open and pass SQLite's integrity check.
for CFG in "$B"/truenas/*.tar; do
    [ -e "$CFG" ] || continue
    mkdir -p "$TMP/cfg"
    if tar -xf "$CFG" -C "$TMP/cfg" && DBF="$(find "$TMP/cfg" -name freenas-v1.db | head -n1)" && [ -n "$DBF" ] \
        && [ "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("PRAGMA integrity_check").fetchone()[0])' "$DBF" 2>/dev/null)" = ok ] \
        && [ -s "$(find "$TMP/cfg" -name pwenc_secret | head -n1)" ]; then
        ok "TrueNAS configuration: database intact, secret seed present"
    else
        bad "TrueNAS configuration $(basename "$CFG")"
    fi
    rm -rf "$TMP/cfg"
done

N=0
for J in "$B"/app-configs/*.json; do
    [ -e "$J" ] || continue
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$J" 2>/dev/null; then N=$((N + 1)); else bad "app setting $(basename "$J")"; fi
done
[ "$N" -gt 0 ] && ok "app settings ($N files)"

# Archives: decompress everything, so a damaged block anywhere is found.
for A in "$B"/archives/*.tar.gz; do
    [ -e "$A" ] || continue
    if COUNT="$(tar -tzf "$A" | wc -l)" && tar -xzf "$A" -O >/dev/null; then
        ok "archive $(basename "$A" .tar.gz) ($COUNT entries)"
    else
        bad "archive $(basename "$A")"
    fi
done

# wait_ready <container> <log pattern> <command...>: up to 120 s. The official
# images first run a temporary server to initialise, then restart it: wait for
# the log line that ends the initialisation, then for the command to work.
wait_ready() {
    local c="$1" pattern="$2" t=0; shift 2
    until docker logs "$c" 2>&1 | grep -qE "$pattern" && docker exec "$c" "$@" >/dev/null 2>&1; do
        sleep 2; t=$((t + 2)); [ "$t" -lt 120 ] || return 1
    done
}

for D in "$B"/databases/pg-*.dump; do
    [ -e "$D" ] || continue
    NAME="$(basename "$D" .dump)"
    if [ "$(head -c 5 "$D")" != PGDMP ]; then bad "$NAME: not a pg_dump archive"; continue; fi
    if [ "$RESTORE" = no ]; then ok "$NAME: pg_dump format"; continue; fi
    C="sb-verify-pg-$$-${#CONTAINERS[@]}"
    CONTAINERS+=("$C")
    if docker run -d --rm --name "$C" --network none -e POSTGRES_PASSWORD=verify "$PG_IMAGE" >/dev/null \
        && wait_ready "$C" 'PostgreSQL init process complete' psql -U postgres -c 'select 1' \
        && docker exec "$C" createdb -U postgres restored \
        && docker exec -i "$C" pg_restore -U postgres --no-owner --no-acl --exit-on-error -d restored <"$D" \
        && T="$(docker exec "$C" psql -U postgres -d restored -tAc "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')")" \
        && [ "$T" -gt 0 ]; then
        ok "$NAME: restored into $PG_IMAGE, $T tables"
    else
        bad "$NAME: restore into $PG_IMAGE failed"
    fi
    docker rm -f "$C" >/dev/null 2>&1
done

for D in "$B"/databases/mysql-*.sql.gz; do
    [ -e "$D" ] || continue
    NAME="$(basename "$D" .sql.gz)"
    if ! zcat "$D" | tail -n 1 | grep -q '^-- Dump completed'; then bad "$NAME: dump incomplete"; continue; fi
    if [ "$RESTORE" = no ]; then ok "$NAME: dump complete"; continue; fi
    C="sb-verify-my-$$-${#CONTAINERS[@]}"
    CONTAINERS+=("$C")
    if docker run -d --rm --name "$C" --network none -e MARIADB_ROOT_PASSWORD=verify -e MARIADB_DATABASE=restored "$MYSQL_IMAGE" >/dev/null \
        && wait_ready "$C" '(MariaDB|MySQL) init process done' mariadb -uroot -pverify -e 'select 1' restored \
        && zcat "$D" | docker exec -i "$C" mariadb -uroot -pverify restored \
        && T="$(docker exec "$C" mariadb -uroot -pverify -N -e "select count(*) from information_schema.tables where table_schema='restored'")" \
        && [ "$T" -gt 0 ]; then
        ok "$NAME: restored into $MYSQL_IMAGE, $T tables"
    else
        bad "$NAME: restore into $MYSQL_IMAGE failed"
    fi
    docker rm -f "$C" >/dev/null 2>&1
done

STATUS=OK; [ "$ERRORS" -eq 0 ] || STATUS=ERROR
write_status "$BACKUP_DIR/status/last_verify.json" status="$STATUS" backup="$(basename "$B")" restore="$RESTORE" errors="$ERRORS" time="$(date +%s)"
if [ "$ERRORS" -eq 0 ]; then
    log "Backup $(basename "$B") verified$([ "$RESTORE" = yes ] && echo ", databases restored")"
    exit 0
fi
log "Backup $(basename "$B"): $ERRORS checks FAILED"
notify error "backup verification FAILED" "Backup $(basename "$B"): $ERRORS checks failed"
exit 1
