#!/bin/bash
# Heartbeat: run as root from cron every minute. Independent, optional parts:
#
#  1. NAS alive -> ping a heartbeat URL (HEALTHCHECKS_URL: Healthchecks.io or any
#     service that takes a GET as a ping). If the NAS shuts down or loses
#     internet the pings stop, and the alert comes from outside the NAS.
#  2. Tailscale state -> Uptime Kuma push monitor (KUMA_URL + KUMA_TOKEN): up when
#     the Tailscale container reports "Running", down otherwise.
#  3. Generic checks (CHECKS): any command, exit code 0 = up, each with its own
#     Kuma push monitor.
#  Notifications (NOTIFY_URL): when a check of part 2 or 3 goes down or comes
#  back up, send one message to ntfy or to a webhook (JSON).
#
# Settings: heartbeat.conf next to this script (see heartbeat.conf.example).
# A part without its settings is skipped. Pause everything: create a PAUSE file here.
set -u
DIR="$(dirname "$(readlink -f "$0")")"
CONF="$DIR/heartbeat.conf"
STATE_DIR="$DIR/state"

HEALTHCHECKS_URL=""
KUMA_URL=""
KUMA_TOKEN=""
TAILSCALE_CONTAINER="ix-tailscale-tailscale-1"
CHECKS=()            # "NAME|KUMA_TOKEN|COMMAND"; the token can be empty
CHECK_TIMEOUT=20     # seconds per check command
NOTIFY_URL=""        # ntfy topic URL (https://ntfy.sh/<topic>) or webhook URL
NOTIFY_FORMAT="ntfy" # ntfy (plain text + headers) or json
NOTIFY_TOKEN=""      # optional: sent as "Authorization: Bearer <token>"

[ -f "$DIR/PAUSE" ] && exit 0
if [ -f "$CONF" ]; then
  # The file holds secret URLs: warn if other users can read it.
  if [ -n "$(find "$CONF" -perm /044 2>/dev/null)" ]; then
    echo "heartbeat: $CONF is readable by other users, run: chmod 600 $CONF" >&2
  fi
  # shellcheck source=/dev/null
  . "$CONF"
fi

fail() { echo "heartbeat: $*" >&2; exit 1; }
for C in ${CHECKS[@]+"${CHECKS[@]}"}; do
  IFS='|' read -r name token cmd <<<"$C"
  [[ "$C" == *"|"*"|"* && "$name" =~ ^[A-Za-z0-9._-]+$ && -n "$cmd" ]] \
    || fail "invalid CHECKS entry '$C' in $CONF: use \"NAME|KUMA_TOKEN|COMMAND\" (NAME: letters, digits, . _ -)"
  [ -z "$token" ] || [ -n "$KUMA_URL" ] || fail "check '$name' has a Kuma token but KUMA_URL is empty"
done
[[ "$CHECK_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail "CHECK_TIMEOUT must be a number of seconds"
case "$NOTIFY_FORMAT" in ntfy|json) ;; *) fail "NOTIFY_FORMAT must be ntfy or json" ;; esac
TAILSCALE=no
[ -n "$KUMA_URL" ] && [ -n "$KUMA_TOKEN" ] && TAILSCALE=yes
if [ -z "$HEALTHCHECKS_URL" ] && [ "$TAILSCALE" = no ] && [ "${#CHECKS[@]}" -eq 0 ]; then
  fail "nothing to do, set HEALTHCHECKS_URL, KUMA_URL + KUMA_TOKEN and/or CHECKS in $CONF"
fi

# One run at a time: slow checks must not pile up when cron starts the next one.
exec 9>"$DIR/.heartbeat.lock"
if ! flock -n 9; then
  echo "heartbeat: previous run still in progress, skipping" >&2
  exit 0
fi

# Send one message to NOTIFY_URL. Arguments: check name, up|down, message.
notify() {
  local host title auth=()
  host="$(hostname)"
  [ -n "$NOTIFY_TOKEN" ] && auth=(-H "Authorization: Bearer $NOTIFY_TOKEN")
  if [ "$NOTIFY_FORMAT" = json ]; then
    python3 -c 'import json,sys,time; print(json.dumps({"host": sys.argv[1], "check": sys.argv[2], "status": sys.argv[3], "msg": sys.argv[4], "time": int(time.time())}))' \
      "$host" "$1" "$2" "$3" \
      | curl -fsS -m 10 -o /dev/null ${auth[@]+"${auth[@]}"} -H "Content-Type: application/json" --data-binary @- "$NOTIFY_URL"
  else
    if [ "$2" = down ]; then title="$host: $1 is DOWN"; else title="$host: $1 is back up"; fi
    curl -fsS -m 10 -o /dev/null ${auth[@]+"${auth[@]}"} -H "Title: $title" \
      -H "Tags: $([ "$2" = down ] && echo rotating_light || echo white_check_mark)" \
      -H "Priority: $([ "$2" = down ] && echo high || echo default)" \
      --data-binary "$3" "$NOTIFY_URL"
  fi || echo "heartbeat: notification for $1 failed" >&2
}

# Report the state of a check. Arguments: name, Kuma token (or empty), up|down,
# message, duration in ms (or empty).
report() {
  local name="$1" token="$2" status="$3" msg="$4" ping="$5" last=""
  if [ -n "$token" ]; then
    curl -fsS -m 10 -o /dev/null -G "${KUMA_URL%/}/api/push/$token" \
      --data-urlencode "status=$status" --data-urlencode "msg=$msg" \
      ${ping:+--data-urlencode "ping=$ping"} \
      || echo "heartbeat: Uptime Kuma push for $name failed" >&2
  fi
  [ -n "$NOTIFY_URL" ] || return 0
  # Notify on changes only; a first run notifies only if the check is down.
  mkdir -p "$STATE_DIR"
  [ -f "$STATE_DIR/$name" ] && last="$(cat "$STATE_DIR/$name")"
  if [ "$status" != "${last:-up}" ]; then notify "$name" "$status" "$msg"; fi
  echo "$status" >"$STATE_DIR/$name"
}

# Part 1: NAS alive
if [ -n "$HEALTHCHECKS_URL" ]; then
  curl -fsS -m 10 --retry 3 -o /dev/null "$HEALTHCHECKS_URL" \
    || echo "heartbeat: heartbeat ping failed" >&2
fi

# Part 2: Tailscale state -> Uptime Kuma
if [ "$TAILSCALE" = yes ]; then
  state=$(docker exec "$TAILSCALE_CONTAINER" tailscale status --json 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("BackendState","?"))' 2>/dev/null)
  [ -z "$state" ] && state="container unreachable"
  if [ "$state" = "Running" ]; then st=up; else st=down; fi
  report tailscale "$KUMA_TOKEN" "$st" "Tailscale $state" ""
fi

# Part 3: generic checks
for C in ${CHECKS[@]+"${CHECKS[@]}"}; do
  IFS='|' read -r name token cmd <<<"$C"
  start=${EPOCHREALTIME//[.,]/}
  out=$(timeout "$CHECK_TIMEOUT" bash -c "$cmd" 2>&1 </dev/null)
  rc=$?
  ms=$(( (${EPOCHREALTIME//[.,]/} - start) / 1000 ))   # EPOCHREALTIME: bash 5, microseconds
  first=$(printf '%s\n' "$out" | head -n 1 | cut -c1-100)
  if [ "$rc" -eq 0 ]; then
    report "$name" "$token" up "${first:-OK}" "$ms"
  elif [ "$rc" -eq 124 ]; then
    report "$name" "$token" down "timed out after ${CHECK_TIMEOUT}s" "$ms"
  else
    report "$name" "$token" down "exit $rc${first:+: $first}" "$ms"
  fi
done
exit 0
