#!/bin/bash
# End-to-end test of system-backup with real databases: starts PostgreSQL 16 and
# MariaDB 11 containers with a few tables, backs them up (TRUENAS_CONFIG=no, so
# no TrueNAS is needed), then restores the dumps with system-backup-verify.sh
# --restore into PostgreSQL 18 and MariaDB 11. Needs docker, bash 5, GNU tools:
#
#   bash tests/system-backup-restore-test.sh
#   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD":/src:ro python:3.13-alpine \
#     sh -c 'apk add -q bash coreutils tar findutils util-linux docker-cli && bash /src/tests/system-backup-restore-test.sh'
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
PG="sbt-pg-$$"
MY="sbt-my-$$"
FAIL=0
# shellcheck disable=SC2329  # called by the trap
cleanup() { docker rm -f "$PG" "$MY" >/dev/null 2>&1; rm -rf "${B:-}"; }
trap cleanup EXIT

check() {
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; FAIL=1; fi
}
ready() {   # ready <container> <log pattern> <command...>
    local c="$1" pattern="$2" t=0; shift 2
    until docker logs "$c" 2>&1 | grep -qE "$pattern" && docker exec "$c" "$@" >/dev/null 2>&1; do
        sleep 2; t=$((t + 2)); [ "$t" -lt 120 ] || { echo "FAIL $c did not start"; docker logs "$c" | tail -n 20; exit 1; }
    done
}

docker run -d --name "$PG" -e POSTGRES_USER=app -e POSTGRES_PASSWORD=apppw -e POSTGRES_DB=appdb postgres:16-alpine >/dev/null
docker run -d --name "$MY" -e MARIADB_ROOT_PASSWORD=rootpw -e MARIADB_USER=app -e MARIADB_PASSWORD=apppw \
    -e MARIADB_DATABASE=shop mariadb:11 >/dev/null
ready "$PG" 'PostgreSQL init process complete' psql -U app -d appdb -c 'select 1'
ready "$MY" '(MariaDB|MySQL) init process done' mariadb -uapp -papppw shop -e 'select 1'
docker exec "$PG" psql -q -U app -d appdb -c \
    "create table users (id int primary key, name text); insert into users values (1, 'ada'), (2, 'linus');
     create table orders (id int primary key, user_id int references users(id)); insert into orders values (10, 1);"
docker exec "$MY" mariadb -uapp -papppw shop -e \
    "create table products (id int primary key, name text); insert into products values (1, 'disk');
     create table stock (product_id int, qty int); insert into stock values (1, 4);"
docker exec "$MY" mariadb -uroot -prootpw -e \
    "create database crm; create table crm.contacts (id int primary key, email text); insert into crm.contacts values (1, 'a@b.c');"

B="$(mktemp -d)"
mkdir -p "$B/data" && echo hello >"$B/data/file.txt"
export SYSTEM_BACKUP_CONF="$B/system-backup.conf"
cat >"$SYSTEM_BACKUP_CONF" <<EOF
BACKUP_DIR="$B/backups"
MIN_FREE_GB=0
TRUENAS_CONFIG=no
PG_DUMPS=("$PG app appdb")
MYSQL_DUMPS=("$MY app shop" "$MY root crm")
ARCHIVES=("data||$B/data||$B/data/file.txt")
EOF
chmod 600 "$SYSTEM_BACKUP_CONF"
mkdir -p "$B/backups"

bash "$SRC/system-backup/system-backup.sh" >"$B/out" 2>&1
check "backup: exit code" 0 $?
L="$B/backups/latest"
check "backup: one PostgreSQL dump, globals, two MariaDB dumps" \
    "mysql-$MY-crm.sql.gz mysql-$MY-shop.sql.gz pg-$PG-appdb.dump pg-$PG-globals.sql" \
    "$(find -L "$L/databases" -type f -printf '%f\n' | sort | paste -sd' ')"
check "backup: no password on this host's command line or in the log" 0 "$(grep -c 'apppw\|rootpw' "$B/out" || true)"

bash "$SRC/system-backup/system-backup-verify.sh" --restore >"$B/vout" 2>&1
check "verify --restore: exit code" 0 $?
check "verify --restore: PostgreSQL 16 dump restored into 18, 2 tables" 1 \
    "$(grep -c "pg-$PG-appdb: restored into postgres:18-alpine, 2 tables" "$B/vout")"
check "verify --restore: MariaDB dump (user app) restored, 2 tables" 1 \
    "$(grep -c "mysql-$MY-shop: restored into mariadb:11, 2 tables" "$B/vout")"
check "verify --restore: MariaDB dump (user root) restored, 1 table" 1 \
    "$(grep -c "mysql-$MY-crm: restored into mariadb:11, 1 tables" "$B/vout")"
check "verify --restore: no container left" 0 "$(docker ps -aq --filter name=sb-verify- | wc -l)"

# A truncated dump must be caught.
D="$(find -L "$L/databases" -name 'mysql-*-shop.sql.gz')"
zcat "$D" | head -n 20 | gzip >"$D.tmp" && mv "$D.tmp" "$D"
bash "$SRC/system-backup/system-backup-verify.sh" >"$B/vout" 2>&1
check "truncated dump: exit code 1" 1 $?
check "truncated dump: found" 1 "$(grep -c 'dump incomplete' "$B/vout")"

[ "$FAIL" -eq 0 ] || { echo "--- backup log"; cat "$B/out"; echo "--- verify log"; cat "$B/vout"; echo "some restore tests FAILED"; exit 1; }
echo "all restore tests passed"
