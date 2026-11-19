#!/bin/bash
# Tests for heartbeat with fake curl and docker: nothing leaves the machine.
# Needs bash 5, GNU timeout, flock and python3 (as on TrueNAS):
#
#   bash tests/heartbeat-test.sh
#   docker run --rm -v "$PWD":/src:ro python:3.13-alpine \
#     sh -c 'apk add -q bash coreutils util-linux && bash /src/tests/heartbeat-test.sh'
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp -d)"
FAIL=0

# curl: one line per call, arguments separated by "|", stdin appended when read.
cat >"$BIN/curl" <<'EOF'
#!/bin/bash
line="$(IFS='|'; printf '%s' "$*")"
for a in "$@"; do [ "$a" = @- ] && line="$line|STDIN=$(cat)"; done
echo "$line" >>"$CURL_LOG"
[ -z "${CURL_FAIL:-}" ]
EOF
# docker: answers "tailscale status --json" with $TS_STATE, fails if it is empty.
cat >"$BIN/docker" <<'EOF'
#!/bin/bash
[ -n "${TS_STATE:-}" ] || exit 1
printf '{"BackendState": "%s"}\n' "$TS_STATE"
EOF
chmod +x "$BIN/curl" "$BIN/docker"
export PATH="$BIN:$PATH"
export TOOLKIT_CONF=/nonexistent   # no shared settings unless a test sets them

check() {   # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; FAIL=1; fi
}
setup() {   # fresh folder with the script and the given settings
    W="$(mktemp -d)"
    cp "$SRC/heartbeat/heartbeat.sh" "$W/"
    printf '%s\n' "$1" >"$W/heartbeat.conf"
    chmod 600 "$W/heartbeat.conf"
    export CURL_LOG="$W/curl.log"
    : >"$CURL_LOG"
}
run() { bash "$W/heartbeat.sh" 2>"$W/stderr"; }
calls() { grep -c -- "${1:-.}" "$CURL_LOG" || true; }

setup ''
run; check "nothing configured: exit code 1" 1 $?
check "nothing configured: message" 1 "$(grep -c 'nothing to do' "$W/stderr")"

setup 'HEALTHCHECKS_URL="https://hc.example/ping/abc"'
touch "$W/PAUSE"; run
check "PAUSE: exit code 0" 0 $?
check "PAUSE: no requests" 0 "$(calls)"
rm "$W/PAUSE"; run
check "heartbeat ping: one request to the URL" 1 "$(calls 'https://hc.example/ping/abc')"
chmod 644 "$W/heartbeat.conf"; run
check "readable settings file: warning" 1 "$(grep -c 'readable by other users' "$W/stderr")"

setup 'KUMA_URL="http://kuma.test/"
KUMA_TOKEN="ts1"'
TS_STATE=Running run
check "tailscale running: push up" 1 "$(calls 'http://kuma.test/api/push/ts1|--data-urlencode|status=up|--data-urlencode|msg=Tailscale Running')"
TS_STATE="" run
check "tailscale container unreachable: push down" 1 "$(calls 'status=down|--data-urlencode|msg=Tailscale container unreachable')"
TS_STATE=Stopped run
check "tailscale stopped: push down" 1 "$(calls 'msg=Tailscale Stopped')"

setup 'KUMA_URL="http://kuma.test"
CHECK_TIMEOUT=1
CHECKS=(
  "ok|t1|echo fine; echo second line"
  "bad|t2|echo boom; exit 3"
  "slow|t3|sleep 5"
  "silent|t4|true"
  "nokuma||true"
)'
run; check "checks: exit code 0" 0 $?
check "check up: first line of output" 1 "$(calls 'push/t1|.*status=up|--data-urlencode|msg=fine|--data-urlencode|ping=[0-9]')"
check "check down: exit code and output" 1 "$(calls 'push/t2|.*status=down|--data-urlencode|msg=exit 3: boom|')"
check "check timeout" 1 "$(calls 'push/t3|.*status=down|--data-urlencode|msg=timed out after 1s|')"
check "check without output: OK" 1 "$(calls 'push/t4|.*msg=OK|')"
check "check without token: no push" 4 "$(calls 'api/push')"
check "no Tailscale part without KUMA_TOKEN" 0 "$(calls 'Tailscale')"

for bad in 'CHECKS=("just a command")' 'CHECKS=("bad name|t|true")' 'CHECKS=("x||")' \
           'CHECKS=("x|t|true")' 'CHECKS=("x||true")
CHECK_TIMEOUT=0' 'CHECKS=("x||true")
NOTIFY_FORMAT=xml'; do
    setup "$bad"; run; rc=$?
    check "bad settings ($(head -n1 <<<"$bad")): exit code 1, no requests" "1 0" "$rc $(calls)"
done

# Notifications: once per change, never on repeated states.
setup 'NOTIFY_URL="https://ntfy.example/topic"
CHECKS=("web||exit 1" "disk||true")'
run
check "ntfy: first run notifies only the check that is down" 1 "$(calls)"
check "ntfy: title, priority and body" 1 "$(calls 'Title: .*: web is DOWN|-H|Tags: rotating_light|-H|Priority: high|--data-binary|exit 1|https://ntfy.example/topic')"
run
check "ntfy: same state, no new message" 1 "$(calls)"
sed -i 's/web||exit 1/web||true/' "$W/heartbeat.conf"; run
check "ntfy: back up" 1 "$(calls 'Title: .*: web is back up|-H|Tags: white_check_mark|-H|Priority: default')"
check "ntfy: state files" "up up" "$(cat "$W/state/web" "$W/state/disk" | tr '\n' ' ' | sed 's/ $//')"

setup 'NOTIFY_URL="https://hooks.example/x"
NOTIFY_FORMAT=json
NOTIFY_TOKEN="secret1"
CHECKS=("db||echo \"conn refused\"; exit 2")'
run
check "webhook: bearer token and JSON header" 1 "$(calls 'Authorization: Bearer secret1|-H|Content-Type: application/json')"
payload="$(grep -o 'STDIN=.*' "$CURL_LOG" | cut -d= -f2-)"
check "webhook: JSON payload" "db down exit 2: conn refused" \
    "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["check"], d["status"], d["msg"])' "$payload")"

setup 'HEALTHCHECKS_URL="https://hc.example/ping/abc"
KUMA_URL="http://kuma.test"
CHECKS=("x|t|true")'
CURL_FAIL=1 run
check "requests failing: exit code 0" 0 $?
check "requests failing: one warning each" 2 "$(grep -c 'failed' "$W/stderr")"

# Shared settings: an empty value in heartbeat.conf uses toolkit.conf.
TKF="$(mktemp)"; chmod 600 "$TKF"
printf 'NOTIFY_URL="https://shared.example/t"\nNOTIFY_FORMAT=json\nKUMA_URL="http://shared-kuma"\n' >"$TKF"
setup 'NOTIFY_URL=""
NOTIFY_FORMAT="ntfy"
KUMA_URL=""
CHECKS=("web|t9|exit 1")'
TOOLKIT_CONF="$TKF" run
check "toolkit.conf: Kuma address used" 1 "$(calls 'http://shared-kuma/api/push/t9')"
check "toolkit.conf: notification settings used together" 1 "$(calls 'Content-Type: application/json|--data-binary|@-|https://shared.example/t')"
setup 'NOTIFY_URL="https://own.example/t"
CHECKS=("web||exit 1")'
TOOLKIT_CONF="$TKF" run
check "toolkit.conf: own NOTIFY_URL wins, with its own format" 1 "$(calls 'Title: .*web is DOWN.*https://own.example/t')"
check "toolkit.conf: shared address not used" 0 "$(calls 'shared.example')"
rm -f "$TKF"

# A run still in progress keeps the lock: the next one skips.
setup 'HEALTHCHECKS_URL="https://hc.example/ping/abc"'
flock "$W/.heartbeat.lock" sleep 3 & sleep 0.5
run; check "lock held: exit code 0" 0 $?
check "lock held: skipped, no requests" "1 0" "$(grep -c 'still in progress' "$W/stderr") $(calls)"
wait

if [ "$FAIL" -ne 0 ]; then echo "some heartbeat tests FAILED"; exit 1; fi
echo "all heartbeat tests passed"
